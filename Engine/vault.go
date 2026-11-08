// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rclone/rclone/backend/crypt"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/object"
)

const (
	controlFolder = ".cloudmount"
	vaultFolder   = controlFolder + "/vault"
	vaultFormat   = 1
)

// A vault problem stops a drive from opening, so a wrong password or wrong folder
// can never lead to files being written with a second key.
var (
	errWrongPassword    = errors.New("the encryption password is wrong, or the vault marker was changed")
	errVaultMissing     = errors.New("this folder has files but no vault marker")
	errVaultNotCreated  = errors.New("this folder has no vault yet")
	errVaultMismatch    = errors.New("this folder holds a different vault from the one this drive used")
	errVaultRollback    = errors.New("the vault marker is older than the one this device last saw")
	errVaultRetired     = errors.New("this vault was retired by a password change")
	errVaultUnsupported = errors.New("this vault needs a newer version of the app")
	errVaultMalformed   = errors.New("the vault marker can't be read")
	// errVaultOnPlainDrive stops a vault being opened as a plain drive.
	errVaultOnPlainDrive = errors.New("this folder holds an encrypted drive")
)

// vaultCheckEvery limits how often a busy drive re-reads the marker before a write.
const vaultCheckEvery = 5 * time.Second

// openVault is the vault a drive opened. It's rechecked while the drive is open, so a client
// that's been running for days stops writing once another device retires the vault.
type openVault struct {
	id       string
	password string

	mu sync.Mutex
	// marker is the last one verified, whole. Any difference at all gets verified again.
	marker  vaultMarker
	checked time.Time
}

// checkVault re-reads the marker. Writes wait on this, so a marker that can't be read holds
// them back rather than letting them through. Unless always is set, a recent check counts.
func (d *drive) checkVault(ctx context.Context, always bool) error {
	if d.vault == nil {
		return d.checkStillPlain(ctx, always)
	}
	v := d.vault
	v.mu.Lock()
	defer v.mu.Unlock()
	if !always && time.Since(v.checked) < vaultCheckEvery {
		return v.marker.refuseIfRetired()
	}
	marker, err := loadVaultMarker(ctx, d.plain)
	if err != nil {
		return err
	}
	if marker == nil {
		return errVaultMissing
	}
	switch {
	case marker.Format > vaultFormat:
		return errVaultUnsupported
	case marker.Revision < v.marker.Revision:
		return errVaultRollback
	}
	// Verifying runs scrypt, so only a changed marker is worth verifying. That means any field:
	// the check alone can be copied onto edited fields.
	if *marker != v.marker {
		if err := marker.verify(v.password); err != nil {
			return err
		}
	}
	switch {
	case marker.VaultID != v.id:
		return errVaultMismatch
	case marker.Salt != v.marker.Salt, marker.Crypt != v.marker.Crypt:
		// The cipher in use came from the old values, so it can't follow these.
		return errVaultMismatch
	}
	// This comes before acting on the state: a retired revision that later vanishes is a server
	// restored from a backup, not a vault that's fine again.
	v.marker, v.checked = *marker, time.Now()
	return marker.refuseIfRetired()
}

// checkStillPlain stops a plain drive writing beside a vault another device made after this one
// opened. An empty folder can become either, and plain text in a vault can't be taken back. A
// marker that can't be read holds writes back, as it does on an encrypted drive.
func (d *drive) checkStillPlain(ctx context.Context, always bool) error {
	d.plainCheck.Lock()
	defer d.plainCheck.Unlock()
	if !always && time.Since(d.plainChecked) < vaultCheckEvery {
		return nil
	}
	marker, err := loadVaultMarker(ctx, d.plain)
	if err != nil {
		return err
	}
	if marker != nil {
		return errVaultOnPlainDrive
	}
	d.plainChecked = time.Now()
	return nil
}

func (m vaultMarker) refuseIfRetired() error {
	if m.State != "active" {
		return errVaultRetired
	}
	return nil
}

// vaultRevision is the highest revision this drive has seen, for the app to keep between runs.
func (d *drive) vaultRevision() int {
	if d.vault == nil {
		return 0
	}
	d.vault.mu.Lock()
	defer d.vault.mu.Unlock()
	return d.vault.marker.Revision
}

type cryptOptions struct {
	FilenameEncryption      string `json:"filenameEncryption"`
	DirectoryNameEncryption bool   `json:"directoryNameEncryption"`
	FilenameEncoding        string `json:"filenameEncoding"`
}

// vaultMarker is .cloudmount/vault/<revision>.json. Check authenticates every other
// field with the vault key, so a wrong password or an edited field is always detected.
type vaultMarker struct {
	Format   int          `json:"format"`
	VaultID  string       `json:"vaultID"`
	Salt     string       `json:"salt"`
	Crypt    cryptOptions `json:"crypt"`
	State    string       `json:"state"`
	Revision int          `json:"revision"`
	Check    string       `json:"check"`
}

// vaultInfo is what a device pins after a successful open.
type vaultInfo struct {
	VaultID  string `json:"vaultID"`
	Revision int    `json:"revision"`
}

func defaultCryptOptions() cryptOptions {
	return cryptOptions{
		FilenameEncryption:      "standard",
		DirectoryNameEncryption: true,
		FilenameEncoding:        "base32",
	}
}

func (m vaultMarker) digest() ([]byte, error) {
	m.Check = ""
	encoded, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(encoded)
	return sum[:], nil
}

func (m vaultMarker) cipher(password string) (*crypt.Cipher, error) {
	vaultPassword, err := obscured(password)
	if err != nil {
		return nil, err
	}
	salt, err := obscured(m.Salt)
	if err != nil {
		return nil, err
	}
	return crypt.NewCipher(configmap.Simple{
		"password":                  vaultPassword,
		"password2":                 salt,
		"filename_encryption":       m.Crypt.FilenameEncryption,
		"directory_name_encryption": strconv.FormatBool(m.Crypt.DirectoryNameEncryption),
		"filename_encoding":         m.Crypt.FilenameEncoding,
		"suffix":                    ".bin",
	})
}

func (m *vaultMarker) seal(password string) error {
	digest, err := m.digest()
	if err != nil {
		return err
	}
	cipher, err := m.cipher(password)
	if err != nil {
		return err
	}
	encrypted, err := cipher.EncryptData(bytes.NewReader(digest))
	if err != nil {
		return err
	}
	sealed, err := io.ReadAll(encrypted)
	if err != nil {
		return err
	}
	m.Check = base64.StdEncoding.EncodeToString(sealed)
	return nil
}

func (m vaultMarker) verify(password string) error {
	sealed, err := base64.StdEncoding.DecodeString(m.Check)
	if err != nil {
		return errVaultMalformed
	}
	cipher, err := m.cipher(password)
	if err != nil {
		return err
	}
	decrypted, err := cipher.DecryptData(io.NopCloser(bytes.NewReader(sealed)))
	if err != nil {
		return errWrongPassword
	}
	defer decrypted.Close()
	got, err := io.ReadAll(decrypted)
	if err != nil {
		return errWrongPassword
	}
	want, err := m.digest()
	if err != nil {
		return err
	}
	if !bytes.Equal(got, want) {
		return errWrongPassword
	}
	return nil
}

func newVaultMarker(password string) (vaultMarker, error) {
	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		return vaultMarker{}, err
	}
	marker := vaultMarker{
		Format:   vaultFormat,
		VaultID:  uuid.NewString(),
		Salt:     base64.StdEncoding.EncodeToString(salt),
		Crypt:    defaultCryptOptions(),
		State:    "active",
		Revision: 1,
	}
	err := marker.seal(password)
	return marker, err
}

// loadVaultMarker returns the highest revision, or nil if there are no markers.
func loadVaultMarker(ctx context.Context, base fs.Fs) (*vaultMarker, error) {
	entries, err := base.List(ctx, vaultFolder)
	if errors.Is(err, fs.ErrorDirNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var revisions []int
	for _, entry := range entries {
		name := strings.TrimSuffix(path.Base(entry.Remote()), ".json")
		if revision, err := strconv.Atoi(name); err == nil {
			revisions = append(revisions, revision)
		}
	}
	if len(revisions) == 0 {
		return nil, nil
	}
	sort.Sort(sort.Reverse(sort.IntSlice(revisions)))

	remote := fmt.Sprintf("%s/%d.json", vaultFolder, revisions[0])
	file, err := base.NewObject(ctx, remote)
	if err != nil {
		return nil, err
	}
	in, err := file.Open(ctx)
	if err != nil {
		return nil, err
	}
	defer in.Close()
	var marker vaultMarker
	if err := json.NewDecoder(io.LimitReader(in, 64*1024)).Decode(&marker); err != nil {
		return nil, errVaultMalformed
	}
	if marker.Revision != revisions[0] {
		return nil, errVaultMalformed
	}
	return &marker, nil
}

// writeVaultMarker adds a marker with create-if-absent semantics, so two devices
// creating a vault at once get one winner.
func writeVaultMarker(ctx context.Context, base fs.Fs, marker vaultMarker) error {
	remote := fmt.Sprintf("%s/%d.json", vaultFolder, marker.Revision)
	if _, err := base.NewObject(ctx, remote); err == nil {
		return fs.ErrorDirExists
	}
	encoded, err := json.Marshal(marker)
	if err != nil {
		return err
	}
	if err := base.Mkdir(ctx, vaultFolder); err != nil {
		return err
	}
	info := object.NewStaticObjectInfo(remote, time.Now(), int64(len(encoded)), true, nil, base)
	_, err = base.Put(ctx, bytes.NewReader(encoded), info, &fs.HTTPOption{Key: "If-None-Match", Value: "*"})
	return err
}

// folderIsEmpty ignores the control folder.
func folderIsEmpty(ctx context.Context, base fs.Fs) (bool, error) {
	entries, err := base.List(ctx, "")
	if errors.Is(err, fs.ErrorDirNotFound) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		if entry.Remote() != controlFolder {
			return false, nil
		}
	}
	return true, nil
}

// resolveVault verifies the vault before anything can read or write through it. Listing
// can't verify a password, because a wrong password just lists an empty vault.
func resolveVault(ctx context.Context, base fs.Fs, c driveConfig) (vaultMarker, error) {
	marker, err := loadVaultMarker(ctx, base)
	if err != nil {
		return vaultMarker{}, err
	}
	if marker == nil {
		empty, err := folderIsEmpty(ctx, base)
		if err != nil {
			return vaultMarker{}, err
		}
		if !empty {
			return vaultMarker{}, errVaultMissing
		}
		if !c.CreateVault {
			return vaultMarker{}, errVaultNotCreated
		}
		created, err := newVaultMarker(c.VaultPassword)
		if err != nil {
			return vaultMarker{}, err
		}
		writeErr := writeVaultMarker(ctx, base, created)
		if writeErr == nil {
			return created, nil
		}
		// Another device may have won the race, so look for its marker.
		marker, err = loadVaultMarker(ctx, base)
		if err != nil {
			return vaultMarker{}, err
		}
		if marker == nil {
			return vaultMarker{}, fmt.Errorf("couldn't create the vault: %w", writeErr)
		}
	}

	if marker.Format > vaultFormat {
		return vaultMarker{}, errVaultUnsupported
	}
	if err := marker.verify(c.VaultPassword); err != nil {
		return vaultMarker{}, err
	}
	if c.ExpectedVaultID != "" && marker.VaultID != c.ExpectedVaultID {
		return vaultMarker{}, errVaultMismatch
	}
	if marker.Revision < c.MinRevision {
		return vaultMarker{}, errVaultRollback
	}
	if marker.State != "active" {
		return vaultMarker{}, errVaultRetired
	}
	return *marker, nil
}

// resolveVaultClaimed creates a vault under a claim, because two devices setting up at once
// must agree on one key, and neither server has an atomic create-if-absent for files.
func resolveVaultClaimed(
	ctx context.Context, server rawServer, base fs.Fs, c driveConfig,
) (vaultMarker, error) {
	if c.CreateVault && server != nil {
		claim, err := acquireClaim(ctx, server, vaultFolder)
		if err != nil {
			return vaultMarker{}, err
		}
		defer releaseClaim(server, claim)
	}
	return resolveVault(ctx, base, c)
}
