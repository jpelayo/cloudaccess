// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/rclone/rclone/backend/crypt"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/cache"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/config/obscure"
	"github.com/rclone/rclone/fs/object"
	"github.com/rclone/rclone/fs/operations"
)

// driveConfig describes one drive. Secrets arrive here from the Keychain and
// stay in memory.
type driveConfig struct {
	ID            string `json:"id"`
	Kind          string `json:"kind"` // webdav, sftp or local (tests only)
	URL           string `json:"url,omitempty"`
	Host          string `json:"host,omitempty"`
	Port          int    `json:"port,omitempty"`
	User          string `json:"user,omitempty"`
	Password      string `json:"password,omitempty"`
	KeyPEM        string `json:"keyPem,omitempty"`
	KeyPassphrase string `json:"keyPassphrase,omitempty"`
	// HostKey is the SFTP server's key, confirmed by a person and pinned on first use.
	HostKey       string `json:"hostKey,omitempty"`
	RootPath      string `json:"rootPath,omitempty"`
	Encrypted     bool   `json:"encrypted,omitempty"`
	VaultPassword string `json:"vaultPassword,omitempty"`
	// CreateVault allows creating a vault in an empty folder.
	CreateVault bool `json:"createVault,omitempty"`
	// ExpectedVaultID and MinRevision are what this device pinned on first success.
	ExpectedVaultID string `json:"expectedVaultID,omitempty"`
	MinRevision     int    `json:"minRevision,omitempty"`
	// DeviceID separates this device's staging files; DeviceName labels conflict copies.
	DeviceID   string `json:"deviceID,omitempty"`
	DeviceName string `json:"deviceName,omitempty"`
	// AppName says which app and version is writing, as file details record it.
	AppName string `json:"appName,omitempty"`
	// ReadOnly refuses every call that would change the drive.
	ReadOnly bool `json:"readOnly,omitempty"`
	// Mode is safe (the default), unsafe or readOnly. See modes.go.
	Mode string `json:"mode,omitempty"`
	// AllowInsecure is a person's consent to send the password over plain http.
	AllowInsecure bool `json:"allowInsecure,omitempty"`
}

var (
	errReadOnly        = errors.New("this drive is read-only")
	errBadAddress      = errors.New("only https and http addresses can be used")
	errInsecureRefused = errors.New("sending a password over plain http needs your consent")
	errTooSlow         = errors.New("the server is too slow to be usable")
	// errFolderTooSlow is one folder running out of time on a server that's still answering.
	errFolderTooSlow = errors.New("this folder took too long to list")
	errDigestOnly    = errors.New("this server only offers Digest sign-in, which CloudAccess can't use")
	errShortFile     = errors.New("the server sent a different amount of this file than it lists")
	errNotAPlainFile = errors.New("this isn't a plain file, so it can't be uploaded as one")
)

// checkTransport is the last word on where a password can go, whatever the app above it asked
// for. Traffic to this Mac itself never reaches a network, so it needs no consent.
func checkTransport(address string, allowInsecure bool) error {
	parsed, err := url.Parse(address)
	if err != nil {
		return errBadAddress
	}
	switch strings.ToLower(parsed.Scheme) {
	case "https":
		return nil
	case "http":
		host := parsed.Hostname()
		ip := net.ParseIP(host)
		if allowInsecure || host == "localhost" || (ip != nil && ip.IsLoopback()) {
			return nil
		}
		return errInsecureRefused
	}
	return errBadAddress
}

// remoteItem is one file or folder, with paths relative to the drive root.
type remoteItem struct {
	Path        string `json:"path"`
	IsDirectory bool   `json:"isDirectory"`
	Size        int64  `json:"size"`
	// ModifiedNS is the server's own date. Versions depend on it, so file details never change it.
	ModifiedNS int64  `json:"modifiedNs"`
	Version    string `json:"versionID,omitempty"`
	// What the file's details say, when they passed every check. See details.go.
	Kind          string `json:"kind,omitempty"`
	OwnModifiedNS int64  `json:"ownModifiedNs,omitempty"`
	CreatedNS     int64  `json:"createdNs,omitempty"`
	SHA256        string `json:"sha256,omitempty"`
	BundleType    string `json:"bundleType,omitempty"`
	// details are kept so a save that replaces the file can carry them forward.
	details *knownDetails
}

type drive struct {
	f          fs.Fs         // files go through this, encrypted when the drive is
	plain      fs.Fs         // the backend itself, without encryption
	cipher     *crypt.Cipher // nil on a plain drive
	server     rawServer     // nil on a local test drive, which has no commit layer
	deviceID   string
	deviceName string
	// appName says which app and version wrote a file's details, for diagnosis.
	appName  string
	vault    *openVault // nil on a plain drive
	readOnly bool
	// unsafe writes without the control folder: no claims, staging or trash. See modes.go.
	unsafe bool

	plainCheck   sync.Mutex
	plainChecked time.Time

	// Whether the server keeps file details without touching files, once known.
	detailsMu    sync.Mutex
	detailsKnown bool
	detailsKept  bool
	// staged holds what staging learned about each upload still waiting to be committed.
	staged sync.Map
	// policySeen says this drive has read or saved a retention policy since it opened, so one
	// that's missing now is uncertain, not the default.
	policySeen atomic.Bool
}

var (
	drivesMu sync.RWMutex
	drives   = map[string]*drive{}
)

func obscured(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	return obscure.Obscure(value)
}

// openDrive registers in-memory rclone remotes for a drive and connects them. On an
// encrypted drive it verifies the vault first, and returns what the device should pin.
func openDrive(ctx context.Context, c driveConfig) (info *vaultInfo, err error) {
	if c.ID == "" {
		return nil, errors.New("drive id is required")
	}
	readOnly, unsafe, err := driveMode(c)
	if err != nil {
		return nil, err
	}
	c.ReadOnly = readOnly
	if c.ReadOnly && c.CreateVault {
		return nil, errReadOnly
	}
	// A failed open leaves nothing behind: repeated wrong passwords mustn't pile up sessions
	// and configuration holding secrets.
	partial := &drive{}
	defer func() {
		if err != nil {
			partial.release()
			releaseSections(c.ID)
		}
	}()
	base := "ca-" + c.ID
	pass, err := obscured(c.Password)
	if err != nil {
		return nil, err
	}

	set := func(key, value string) {
		if value != "" {
			config.FileSetValue(base, key, value)
		}
	}
	var server rawServer
	switch c.Kind {
	case "webdav":
		if err := checkTransport(c.URL, c.AllowInsecure); err != nil {
			return nil, err
		}
		set("type", "webdav")
		set("url", c.URL)
		set("vendor", "other")
		set("user", c.User)
		set("pass", pass)
		server = newDavClient(ctx, c.URL, c.User, c.Password)
	case "sftp":
		keyPass, err := obscured(c.KeyPassphrase)
		if err != nil {
			return nil, err
		}
		// Connecting first means a changed host key or a server that can't replace files
		// safely is reported as itself, not as a failure inside rclone.
		secure, err := newSFTPServer(c)
		if err != nil {
			return nil, err
		}
		server = secure
		partial.server = secure
		if _, err := secure.connect(ctx); err != nil {
			return nil, err
		}
		set("type", "sftp")
		set("host", c.Host)
		if c.Port != 0 {
			set("port", fmt.Sprint(c.Port))
		}
		set("user", c.User)
		set("pass", pass)
		// rclone unquotes this value, so its line breaks have to be written as \n.
		set("key_pem", strings.ReplaceAll(c.KeyPEM, "\n", `\n`))
		set("key_file_pass", keyPass)
		set("host_keys", c.HostKey)
		// Many servers offer no shell, and rclone must not run commands on them.
		set("shell_type", "none")
		set("disable_hashcheck", "true")
		if lean {
			set("concurrency", fmt.Sprint(sftpRequestsInFlight))
			set("idle_timeout", sftpIdleTimeout)
		}
	case "local":
		set("type", "local")
	default:
		return nil, fmt.Errorf("unknown drive kind %q", c.Kind)
	}

	target := base + ":" + c.RootPath
	plain, err := fs.NewFs(ctx, target)
	if err != nil && !errors.Is(err, fs.ErrorIsFile) {
		return nil, signInProblem(ctx, server, err)
	}
	partial.plain = plain
	var cipher *crypt.Cipher
	var vault *openVault
	if !c.Encrypted {
		// A plain view of a vault would show encrypted names as ordinary files and let
		// plain text be written beside them.
		marker, err := loadVaultMarker(ctx, plain)
		if err != nil {
			return nil, signInProblem(ctx, server, err)
		}
		if marker != nil {
			return nil, errVaultOnPlainDrive
		}
	} else {
		marker, err := resolveVaultClaimed(ctx, server, plain, c)
		if err != nil {
			return nil, signInProblem(ctx, server, err)
		}
		vault = &openVault{
			id: marker.VaultID, marker: marker, password: c.VaultPassword,
		}
		if cipher, err = marker.cipher(c.VaultPassword); err != nil {
			return nil, err
		}
		vaultPass, err := obscured(c.VaultPassword)
		if err != nil {
			return nil, err
		}
		salt, err := obscured(marker.Salt)
		if err != nil {
			return nil, err
		}
		section := base + "-crypt"
		config.FileSetValue(section, "type", "crypt")
		config.FileSetValue(section, "remote", target)
		config.FileSetValue(section, "password", vaultPass)
		config.FileSetValue(section, "password2", salt)
		config.FileSetValue(section, "filename_encryption", marker.Crypt.FilenameEncryption)
		config.FileSetValue(section, "directory_name_encryption", fmt.Sprint(marker.Crypt.DirectoryNameEncryption))
		config.FileSetValue(section, "filename_encoding", marker.Crypt.FilenameEncoding)
		target = section + ":"
		info = &vaultInfo{VaultID: marker.VaultID, Revision: marker.Revision}
	}

	f, err := fs.NewFs(ctx, target)
	if err != nil && !errors.Is(err, fs.ErrorIsFile) {
		return nil, err
	}
	partial.f = f
	opened := &drive{
		f: f, plain: plain, cipher: cipher, server: server, vault: vault,
		deviceID: c.DeviceID, deviceName: c.DeviceName, appName: c.AppName, readOnly: c.ReadOnly,
		unsafe: unsafe,
	}
	if opened.deviceID == "" {
		opened.deviceID = "unknown"
	}
	if opened.deviceName == "" {
		opened.deviceName = "another device"
	}
	drivesMu.Lock()
	drives[c.ID] = opened
	drivesMu.Unlock()
	return info, nil
}

// signInProblem says what's really wrong when a server refuses a sign-in it was never going to
// accept. Every refusal looks like a wrong password otherwise, and that sends someone looking
// in the wrong place. The extra request only runs after a refusal.
func signInProblem(ctx context.Context, server rawServer, err error) error {
	if dav, ok := server.(*davClient); ok && classify(err).Kind == "unauthorized" && dav.offersOnlyDigest(ctx) {
		return errDigestOnly
	}
	return err
}

func closeDrive(id string) {
	drivesMu.Lock()
	opened := drives[id]
	delete(drives, id)
	drivesMu.Unlock()
	if opened == nil {
		return
	}
	opened.release()
	releaseSections(id)
}

// release ends this drive's connections, including rclone's pools.
func (d *drive) release() {
	if secure, ok := d.server.(*sftpServer); ok {
		secure.disconnect(nil)
	}
	if dav, ok := d.server.(*davClient); ok {
		dav.client.CloseIdleConnections()
	}
	shutdownBackend(d.f)
	if d.plain != d.f {
		shutdownBackend(d.plain)
	}
}

func shutdownBackend(f fs.Fs) {
	if f == nil {
		return
	}
	if shutdown := f.Features().Shutdown; shutdown != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdown(ctx)
	}
}

// releaseSections forgets a drive's rclone configuration, which holds its obscured secrets,
// and rclone's cached backends for it.
func releaseSections(id string) {
	for _, section := range []string{"ca-" + id, "ca-" + id + "-crypt"} {
		cache.ClearConfig(section)
		config.LoadedData().DeleteSection(section)
	}
}

func lookupDrive(id string) (*drive, error) {
	drivesMu.RLock()
	defer drivesMu.RUnlock()
	d, ok := drives[id]
	if !ok {
		return nil, fmt.Errorf("drive %q is not open", id)
	}
	return d, nil
}

func cleanPath(p string) string {
	return strings.Trim(p, "/")
}

func (d *drive) itemFromEntry(ctx context.Context, entry fs.DirEntry) remoteItem {
	_, isDir := entry.(fs.Directory)
	item := remoteItem{Path: entry.Remote(), IsDirectory: isDir, Size: entry.Size()}
	if modified := entry.ModTime(ctx); !modified.IsZero() {
		item.ModifiedNS = modified.UnixNano()
	}
	return item
}

func (d *drive) list(ctx context.Context, dir string) ([]remoteItem, error) {
	if d.server != nil {
		return d.serverList(ctx, cleanPath(dir))
	}
	entries, err := d.f.List(ctx, cleanPath(dir))
	if err != nil {
		return nil, err
	}
	if err := checkListingSize(len(entries)); err != nil {
		return nil, err
	}
	items := make([]remoteItem, 0, len(entries))
	for _, entry := range entries {
		// The control folder and the .cm- names are reserved and never shown.
		if isReservedName(entry.Remote()) {
			continue
		}
		items = append(items, d.itemFromEntry(ctx, entry))
	}
	return items, nil
}

// stat finds a file or folder. Backends report folders differently, so a
// missing object falls back to listing the parent folder.
func (d *drive) stat(ctx context.Context, p string) (remoteItem, error) {
	p = cleanPath(p)
	if p == "" {
		return remoteItem{IsDirectory: true}, nil
	}
	if d.server != nil {
		return d.serverStat(ctx, p)
	}
	object, err := d.f.NewObject(ctx, p)
	if err == nil {
		return d.itemFromEntry(ctx, object), nil
	}
	if !errors.Is(err, fs.ErrorIsDir) && !errors.Is(err, fs.ErrorObjectNotFound) {
		return remoteItem{}, err
	}
	parent := path.Dir(p)
	if parent == "." {
		parent = ""
	}
	siblings, listErr := d.list(ctx, parent)
	if listErr != nil {
		return remoteItem{}, listErr
	}
	for _, sibling := range siblings {
		if sibling.Path == p {
			return sibling, nil
		}
	}
	return remoteItem{}, fs.ErrorObjectNotFound
}

// countingWriter reports bytes through a call's progress counter.
type countingWriter struct {
	w     io.Writer
	bytes *atomic.Int64
}

func (c countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.bytes.Add(int64(n))
	return n, err
}

type countingReader struct {
	r     io.Reader
	bytes *atomic.Int64
}

func (c countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.bytes.Add(int64(n))
	return n, err
}

// writeTo copies a stream to a local file through a temporary name, so a failed
// transfer never leaves a partial file at the destination. A size of -1 means it isn't known.
// A stream can end cleanly and early, and on an encrypted drive every chunk that did arrive
// still authenticates, so the size is the only thing that shows some are missing.
// expected is the SHA-256 the file's details recorded, or empty when none is known.
func writeTo(ctx context.Context, source io.Reader, destination string, size int64, bytes *atomic.Int64, expected string) error {
	partial := destination + ".partial"
	out, err := os.Create(partial)
	if err != nil {
		return err
	}
	defer os.Remove(partial)
	hash := sha256.New()
	var hashing io.Writer = io.Discard
	if expected != "" {
		hashing = hash
	}
	written, copyErr := io.Copy(io.MultiWriter(countingWriter{out, bytes}, hashing), steadyReader{r: contextReader{ctx, source}, window: newRateWindow()})
	if closeErr := out.Close(); copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		return copyErr
	}
	if size >= 0 && written != size {
		return errShortFile
	}
	// Checked before the file takes its name, so damaged bytes never reach anyone.
	if expected != "" && hex.EncodeToString(hash.Sum(nil)) != expected {
		return errFileDamaged
	}
	return os.Rename(partial, destination)
}

// A server that sends a byte now and then keeps every timeout happy while Finder waits forever,
// so a transfer has to sustain this rate, measured over this long.
var (
	slowDripWindow = 60 * time.Second
	slowDripFloor  = int64(1024) // bytes a second
)

type rateWindow struct {
	started time.Time
	bytes   int64
}

func newRateWindow() *rateWindow {
	return &rateWindow{started: time.Now()}
}

// steadyReader fails a read that has fallen below the floor for a whole window.
type steadyReader struct {
	r      io.Reader
	window *rateWindow
}

func (s steadyReader) Read(p []byte) (int, error) {
	n, err := s.r.Read(p)
	s.window.bytes += int64(n)
	if elapsed := time.Since(s.window.started); elapsed >= slowDripWindow {
		if float64(s.window.bytes) < elapsed.Seconds()*float64(slowDripFloor) {
			return n, errTooSlow
		}
		*s.window = rateWindow{started: time.Now()}
	}
	return n, err
}

// openWithin opens a file for reading, and gives up if the server doesn't start answering. The
// returned function ends the read, because the stream can't outlive its context.
func openWithin(ctx context.Context, file fs.Object, options ...fs.OpenOption) (io.ReadCloser, context.CancelFunc, error) {
	reading, cancel := context.WithCancel(ctx)
	var tooSlow atomic.Bool
	timer := time.AfterFunc(firstByteLimit, func() {
		tooSlow.Store(true)
		cancel()
	})
	in, err := file.Open(reading, options...)
	timer.Stop()
	if err != nil {
		cancel()
		if tooSlow.Load() {
			return nil, nil, fmt.Errorf("%w: %v", errTooSlow, err)
		}
		return nil, nil, err
	}
	return in, cancel, nil
}

// localReadError is a failure reading a file on this Mac. It comes out of an upload looking like
// a failed request, and a server that can't be reached is a very different thing to tell a
// person, so it's marked where it happens.
type localReadError struct {
	cause error
}

func (e localReadError) Error() string {
	return e.cause.Error()
}

func (e localReadError) Unwrap() error {
	return e.cause
}

// reason is what went wrong, without the path of macOS's private copy.
func (e localReadError) reason() string {
	var failed *os.PathError
	if errors.As(e.cause, &failed) {
		return failed.Err.Error()
	}
	return e.cause.Error()
}

// localFile marks what goes wrong reading a file being sent.
type localFile struct {
	r io.Reader
}

func (l localFile) Read(p []byte) (int, error) {
	n, err := l.r.Read(p)
	if err != nil && err != io.EOF {
		return n, localReadError{err}
	}
	return n, err
}

// openPlainFile opens a file to send. Nothing else can go up as a file: a package is a folder,
// which only fails once the upload has started, and a link would send whatever it points at.
func openPlainFile(source string) (*os.File, os.FileInfo, error) {
	found, err := os.Lstat(source)
	if err != nil {
		return nil, nil, localReadError{err}
	}
	if !found.Mode().IsRegular() {
		return nil, nil, errNotAPlainFile
	}
	file, err := os.Open(source)
	if err != nil {
		return nil, nil, localReadError{err}
	}
	// Asked again of what's really open, because the path could have changed in between.
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, nil, localReadError{err}
	}
	if !info.Mode().IsRegular() {
		file.Close()
		return nil, nil, errNotAPlainFile
	}
	return file, info, nil
}

// contextReader stops a copy as soon as its call is cancelled.
type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (c contextReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

func (d *drive) download(ctx context.Context, p, destination string, bytes *atomic.Int64, expected string) error {
	object, err := d.f.NewObject(ctx, cleanPath(p))
	if err != nil {
		return err
	}
	in, stop, err := openWithin(ctx, object)
	if err != nil {
		return err
	}
	defer stop()
	defer in.Close()
	return writeTo(ctx, in, destination, object.Size(), bytes, expected)
}

func (d *drive) readRange(ctx context.Context, p string, offset, length int64, destination string, bytes *atomic.Int64) error {
	if length <= 0 {
		return errors.New("length must be positive")
	}
	object, err := d.f.NewObject(ctx, cleanPath(p))
	if err != nil {
		return err
	}
	in, stop, err := openWithin(ctx, object, &fs.RangeOption{Start: offset, End: offset + length - 1})
	if err != nil {
		return err
	}
	defer stop()
	defer in.Close()
	// A range can run past the end of a file, so what it should come to isn't known here.
	return writeTo(ctx, in, destination, -1, bytes, "")
}

func (d *drive) upload(ctx context.Context, source, p string, bytes *atomic.Int64) (remoteItem, error) {
	file, info, err := openPlainFile(source)
	if err != nil {
		return remoteItem{}, err
	}
	defer file.Close()
	p = cleanPath(p)
	objectInfo := object.NewStaticObjectInfo(p, info.ModTime(), info.Size(), true, nil, d.f)
	uploaded, err := d.f.Put(ctx, countingReader{contextReader{ctx, localFile{file}}, bytes}, objectInfo)
	if err != nil {
		return remoteItem{}, err
	}
	if d.server != nil {
		return d.serverStat(ctx, p)
	}
	return d.itemFromEntry(ctx, uploaded), nil
}

// mkdir creates a folder and any missing parents.
func (d *drive) mkdir(ctx context.Context, p string) error {
	return d.mkdirWith(ctx, p, time.Time{})
}

// mkdirWith is mkdir, recording when the folder was created on the device that made it. Only a
// folder this request made gets that: one another device made first keeps its own.
func (d *drive) mkdirWith(ctx context.Context, p string, created time.Time) error {
	p = cleanPath(p)
	if err := d.checkName(p); err != nil {
		return err
	}
	if err := d.checkVault(ctx, false); err != nil {
		return err
	}
	if _, ok := d.server.(detailsKeeper); !ok || created.IsZero() || p == "" || !d.keepsDetails(ctx) {
		return d.f.Mkdir(ctx, p)
	}
	raw := d.rawFolder(p)
	made, err := d.server.createExclusive(ctx, raw)
	if err != nil {
		return err
	}
	if made {
		d.describeFolder(ctx, raw, created)
	}
	return nil
}

// probeResult says what the server can do, found at setup.
type probeResult struct {
	Versions bool `json:"versions"`
}

// probe writes a small file inside the control folder, never among user files, to see whether
// the server reports versions. Without them a save can't safely replace anything.
func (d *drive) probe(ctx context.Context) (probeResult, error) {
	if d.server == nil {
		return probeResult{Versions: true}, nil
	}
	name := controlFolder + "/probe-" + uuid.NewString()
	if d.unsafe {
		// Hidden by its name, and removed straight away.
		name = reservedPrefix + "probe-" + uuid.NewString()
	}
	if err := d.writeControlFile(ctx, name, []byte("probe")); err != nil {
		return probeResult{}, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = d.server.remove(cleanup, name, false)
	}()
	entry, err := d.server.statRaw(ctx, name)
	if err != nil {
		return probeResult{}, err
	}
	return probeResult{Versions: entry.ETag != ""}, nil
}

// health asks the server something real, for a poll to find out whether a drive is reachable
// and its vault is still the one it opened.
func (d *drive) health(ctx context.Context) error {
	if d.server != nil {
		if _, err := d.server.statRaw(ctx, ""); err != nil {
			return err
		}
	}
	return d.checkVault(ctx, true)
}

// move relies on the server's own move, so nothing is re-uploaded.
func (d *drive) move(ctx context.Context, source, destination string) error {
	source, destination = cleanPath(source), cleanPath(destination)
	item, err := d.stat(ctx, source)
	if err != nil {
		return err
	}
	if parent := path.Dir(destination); parent != "." {
		if err := d.f.Mkdir(ctx, parent); err != nil {
			return err
		}
	}
	features := d.f.Features()
	if item.IsDirectory {
		if features.DirMove == nil {
			return fs.ErrorCantDirMove
		}
		return features.DirMove(ctx, d.f, source, destination)
	}
	if features.Move == nil {
		return fs.ErrorCantMove
	}
	object, err := d.f.NewObject(ctx, source)
	if err != nil {
		return err
	}
	_, err = features.Move(ctx, object, destination)
	return err
}

// remove deletes a file, or a folder and everything in it.
func (d *drive) remove(ctx context.Context, p string) error {
	p = cleanPath(p)
	item, err := d.stat(ctx, p)
	if err != nil {
		return err
	}
	if item.IsDirectory {
		return operations.Purge(ctx, d.f, p)
	}
	object, err := d.f.NewObject(ctx, p)
	if err != nil {
		return err
	}
	return object.Remove(ctx)
}

// changesTheDrive lists every call that writes to the server. Read-only is checked here, in one
// place, so no path around the app's own checks can write.
var changesTheDrive = map[string]bool{
	"trashRestore": true, "trashPurge": true, "maintain": true, "setPolicy": true, "retireVault": true, "probe": true,
	"upload": true, "save": true, "stage": true, "commit": true, "mkdir": true, "move": true,
	"delete": true, "trash": true, "cleanControlFolder": true,
}

// dispatch runs one engine method. Arguments and results are JSON.
func dispatch(ctx context.Context, method string, arguments []byte, bytes *atomic.Int64) (any, error) {
	var a struct {
		Drive       string `json:"drive"`
		Path        string `json:"path"`
		Source      string `json:"source"`
		Destination string `json:"destination"`
		Staged      string `json:"staged"`
		Offset      int64  `json:"offset"`
		Length      int64  `json:"length"`
		BaseVersion string `json:"baseVersion"`
		// FailOnConflict reports a peer's version as an error instead of keeping both.
		FailOnConflict bool `json:"failOnConflict"`
		// What the saving device knows about the file, for its details.
		ModifiedNS int64  `json:"modifiedNs"`
		CreatedNS  int64  `json:"createdNs"`
		BundleType string `json:"bundleType"`
		// SHA256 is what a download must match, from the file's details, or empty.
		SHA256 string `json:"sha256"`
	}
	if method == "open" {
		var c driveConfig
		if err := json.Unmarshal(arguments, &c); err != nil {
			return nil, err
		}
		info, err := openDrive(ctx, c)
		if err != nil || info == nil {
			return nil, err
		}
		return info, nil
	}
	if method == "trim" {
		trimMemory()
		return nil, nil
	}
	if method == "hostKey" {
		var server struct {
			Host string `json:"host"`
			Port int    `json:"port"`
		}
		if err := json.Unmarshal(arguments, &server); err != nil {
			return nil, err
		}
		return probeHostKey(ctx, server.Host, server.Port)
	}
	if method == "hostKeyFingerprint" {
		var pin struct {
			Key string `json:"key"`
		}
		if err := json.Unmarshal(arguments, &pin); err != nil {
			return nil, err
		}
		return keyFingerprint(pin.Key)
	}
	if err := json.Unmarshal(arguments, &a); err != nil {
		return nil, err
	}
	if method == "close" {
		closeDrive(a.Drive)
		return nil, nil
	}
	d, err := lookupDrive(a.Drive)
	if err != nil {
		return nil, err
	}
	if d.readOnly && changesTheDrive[method] {
		return nil, errReadOnly
	}
	if d.unsafe && needsTrash[method] {
		return nil, errUnsafeKeepsNoTrash
	}
	switch method {
	case "list":
		return d.list(ctx, a.Path)
	case "stat":
		return d.stat(ctx, a.Path)
	case "health":
		return nil, d.health(ctx)
	case "probe":
		return d.probe(ctx)
	case "trashList":
		return d.trashEntries(ctx)
	case "trashRestore":
		return d.restoreFromTrash(ctx, a.Path)
	case "trashPurge":
		return nil, d.purgeFromTrash(ctx, a.Path)
	case "maintain":
		return d.maintain(ctx)
	case "controlFolder":
		return d.controlFolderContents(ctx)
	case "cleanControlFolder":
		return d.cleanControlFolder(ctx)
	case "getPolicy":
		return d.retentionInfo(ctx)
	case "setPolicy":
		return nil, d.setPolicy(ctx, policyLasting(a.Length))
	case "retireVault":
		return nil, d.retireVault(ctx)
	case "vaultDetails":
		return d.vaultDetails(ctx)
	case "vaultRevision":
		return vaultInfo{Revision: d.vaultRevision()}, nil
	case "download":
		return nil, d.download(ctx, a.Path, a.Destination, bytes, a.SHA256)
	case "read":
		return nil, d.readRange(ctx, a.Path, a.Offset, a.Length, a.Destination, bytes)
	case "upload":
		return d.upload(ctx, a.Source, a.Path, bytes)
	case "save":
		return d.saveFile(ctx, a.Source, a.Path, a.BaseVersion, a.FailOnConflict, bytes)
	case "stage":
		return d.stage(ctx, a.Source, bytes)
	case "checkName":
		return nil, d.checkName(cleanPath(a.Path))
	case "commit":
		return d.commitStageWith(ctx, a.Staged, a.Source, a.Path, a.BaseVersion, a.FailOnConflict, bytes, fileInput{
			Modified: nanoTime(a.ModifiedNS), Created: nanoTime(a.CreatedNS), BundleType: a.BundleType,
		})
	case "discardStage":
		d.discardStage(a.Staged)
		return nil, nil
	case "mkdir":
		return nil, d.mkdirWith(ctx, a.Path, nanoTime(a.CreatedNS))
	case "move":
		return d.moveItem(ctx, a.Source, a.Destination, a.BaseVersion)
	case "delete":
		return nil, d.remove(ctx, a.Path)
	case "trash":
		return nil, d.trash(ctx, a.Path, a.BaseVersion)
	}
	return nil, fmt.Errorf("unknown method %q", method)
}

// trimMemory gives memory back to macOS when it's running short. Only idle connections are
// closed, so a save in progress isn't disturbed.
func trimMemory() {
	drivesMu.RLock()
	for _, opened := range drives {
		if dav, ok := opened.server.(*davClient); ok {
			dav.client.CloseIdleConnections()
		}
	}
	drivesMu.RUnlock()
	debug.FreeOSMemory()
}

// configureRclone applies engine-wide settings: no config file, modest logging,
// and timeouts short enough that a stalled server can't hang a read for minutes.
func configureRclone() {
	_ = config.SetConfigPath("/notfound")
	ci := fs.GetConfig(context.Background())
	ci.LogLevel = fs.LogLevelError
	ci.Timeout = fs.Duration(60 * time.Second)
	ci.ConnectTimeout = fs.Duration(15 * time.Second)
	ci.LowLevelRetries = 3
	ci.UserAgent = "CloudAccess"
}

// nanoTime reads a time Swift sent as nanoseconds, where zero means none.
func nanoTime(ns int64) time.Time {
	if ns == 0 {
		return time.Time{}
	}
	return time.Unix(0, ns)
}
