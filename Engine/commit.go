// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/rclone/rclone/backend/webdav/api"
	"github.com/rclone/rclone/fs/object"
)

// The commit layer saves files so that a peer's version is never overwritten.
//
// Conditional requests aren't atomic on Apache: two conditional uploads can both win. But
// creating a folder is atomic on WebDAV and SFTP alike, so it's used as a short lock. While
// a device holds the claim on a path, it checks the version and moves the staged upload
// into place. Only devices using this app respect claims, which is the supported way to
// write to a drive.
//
// Neither server can reject a request from a former claim holder, so ownership is kept by
// agreement: a holder checks its token and its own clock just before its final move, and a
// claim is only taken over long after any holder would have given up.

const (
	claimsFolder   = controlFolder + "/claims"
	structureClaim = claimsFolder + "/structure"
	stagingFolder  = controlFolder + "/staging"
	trashFolder    = controlFolder + "/trash"

	// claimHoldLimit is how long a holder may keep a claim. Past it, a holder neither
	// commits nor releases, so it can't act on a claim that has since been taken over.
	claimHoldLimit = 60 * time.Second
	// claimLiveFor is how long a folder operation waits for a file claim. Its holder has
	// given up by then, so a crashed save can't stall a folder move for long.
	claimLiveFor = 2 * time.Minute
	// claimStaleAfter is when a claim counts as abandoned and can be taken over.
	claimStaleAfter = 10 * time.Minute

	claimWait       = 30 * time.Second
	claimRetry      = 150 * time.Millisecond
	staleCheckEvery = 5 * time.Second
	// A commit that loses its claim starts again from the staged file, this many times.
	commitAttempts = 3
	// settledLimit is how long a request that must not be abandoned gets to finish.
	settledLimit = 30 * time.Second

	// A replaced version waits in the trash under this prefix, for this long.
	versionPrefix   = "v-"
	versionLifetime = 7 * 24 * time.Hour
	// keepCopyLimit bounds how long a copy can hold up a save, because it happens under the
	// claim, and a claim can only be held for a minute.
	keepCopyLimit = 20 * time.Second
	// davCopyBytes is the largest file WebDAV is asked to copy. Its copy takes longer the bigger the
	// file is, where SFTP's hard link is instant at any size. 2 GB took 5 seconds on the Storage
	// Box, and keepCopyLimit covers a slower server.
	davCopyBytes = 2_000_000_000
)

var (
	errTooBigToKeep = errors.New("this file is too big to copy in the time a save can wait")
	errClaimBusy    = errors.New("another device is saving this item")
	errClaimLost    = errors.New("this device's claim expired during the save")
	// errResultUnknown means a commit's request may or may not have reached the server. Its
	// claim stays until it expires, so no peer can commit while that request might still land.
	errResultUnknown = errors.New("the server's answer was lost, so this change may or may not have happened")
	// errNameTaken is its own error, because macOS has to hear "that name is taken". It renames
	// one of the two then, where anything vaguer makes it stop trying for good.
	errNameTaken = errors.New("another item on the server already has this name")
	// errShortUpload means the server kept less than was sent, while answering that it worked.
	errShortUpload = errors.New("the server kept only part of this file, so it wasn't saved")
)

// settled gives a request that must finish its own time limit, free of the caller's cancellation.
// A cancelled request can still reach the server, so these aren't abandoned part way.
func settled(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), settledLimit)
}

// commitMove is the step that puts a change in place. Cancelling can't stop it, and if its answer
// is lost, the error keeps the claim held.
func (d *drive) commitMove(ctx context.Context, from, to string, folder, overwrite bool) error {
	moving, cancel := settled(ctx)
	defer cancel()
	err := d.server.moveRaw(moving, from, to, folder, overwrite)
	if err != nil && (errors.Is(err, context.DeadlineExceeded) || classify(err).Kind == "unreachable" ||
		mayStillLand(err)) {
		return withCause(fmt.Errorf("%w: %v", errResultUnknown, err), err)
	}
	return err
}

// mayStillLand says whether a server error leaves a move's outcome open. A proxy answers 502 or
// 504 when it gives up on the server behind it, which may still carry the move out, and a 500 can
// come after the work is done. Only a full server, 507, says for certain nothing happened.
func mayStillLand(err error) bool {
	var davError *api.Error
	if !errors.As(err, &davError) {
		return false
	}
	return davError.StatusCode >= 500 && davError.StatusCode != http.StatusInsufficientStorage
}

func (c *davClient) mkcol(ctx context.Context, rawPath string) (int, error) {
	response, err := c.do(ctx, "MKCOL", c.address(rawPath, true), nil, nil)
	if err != nil {
		return 0, err
	}
	response.Body.Close()
	return response.StatusCode, nil
}

// alreadyMade reports whether a refused MKCOL only means the folder is there. Apache checks for it
// and then makes it, so two clients can both pass the check, and the loser's mkdir fails as 403,
// not 405. A 403 alone proves nothing, so this looks: no folder means a real refusal.
func (c *davClient) alreadyMade(ctx context.Context, status int, rawPath string) bool {
	switch status {
	case http.StatusMethodNotAllowed:
		return true
	case http.StatusForbidden:
		_, err := c.statRaw(ctx, rawPath)
		return err == nil
	}
	return false
}

// ensureFolder creates a control folder and its parents. An existing folder is fine.
func (c *davClient) ensureFolder(ctx context.Context, rawPath string) error {
	status, err := c.mkcol(ctx, rawPath)
	if err != nil {
		return err
	}
	if status == http.StatusCreated || c.alreadyMade(ctx, status, rawPath) {
		return nil
	}
	if status == http.StatusConflict {
		if rawPath != "" {
			parent := path.Dir(rawPath)
			if parent == "." {
				parent = ""
			}
			if err := c.ensureFolder(ctx, parent); err != nil {
				return err
			}
		}
		status, err = c.mkcol(ctx, rawPath)
		if err != nil {
			return err
		}
		if status == http.StatusCreated || c.alreadyMade(ctx, status, rawPath) {
			return nil
		}
	}
	return statusError(status)
}

func (c *davClient) remove(ctx context.Context, rawPath string, folder bool) error {
	_, err := c.removeFound(ctx, rawPath, folder)
	return err
}

func (c *davClient) removeFound(ctx context.Context, rawPath string, folder bool) (bool, error) {
	response, err := c.do(ctx, "DELETE", c.address(rawPath, folder), nil, nil)
	if err != nil {
		return false, err
	}
	response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if !didAll(response.StatusCode) {
		return false, statusError(response.StatusCode)
	}
	return true, nil
}

// didAll says whether a MOVE, COPY or DELETE did everything it was asked. 207 Multi-Status means
// some members of a folder failed, so part of it may still be where it was. Taking that as done
// would let what's left be cleaned up as if it had moved, such as the rest of a folder being
// restored from the trash.
func didAll(status int) bool {
	return status >= 200 && status < 300 && status != http.StatusMultiStatus
}

// removeAll deletes a folder, which WebDAV's DELETE does recursively.
func (c *davClient) removeAll(ctx context.Context, rawPath string) error {
	return c.remove(ctx, rawPath, true)
}

func (c *davClient) keepCopy(ctx context.Context, from, to string, size int64) error {
	if size > davCopyBytes {
		return errTooBigToKeep
	}
	headers := map[string]string{"Destination": c.address(to, false), "Overwrite": "F", "Depth": "0"}
	response, err := c.do(ctx, "COPY", c.address(from, false), headers, nil)
	if err != nil {
		return err
	}
	response.Body.Close()
	if !didAll(response.StatusCode) {
		return statusError(response.StatusCode)
	}
	return nil
}

// moveRaw moves a resource on the server. With overwrite false it refuses an existing
// destination, though that check isn't atomic on Apache, so callers hold a claim.
func (c *davClient) moveRaw(ctx context.Context, from, to string, folder, overwrite bool) error {
	flag := "F"
	if overwrite {
		flag = "T"
	}
	headers := map[string]string{"Destination": c.address(to, folder), "Overwrite": flag}
	response, err := c.do(ctx, "MOVE", c.address(from, folder), headers, nil)
	if err != nil {
		return err
	}
	response.Body.Close()
	if !didAll(response.StatusCode) {
		return statusError(response.StatusCode)
	}
	return nil
}

func claimPath(rawPath string) string {
	sum := sha256.Sum256([]byte(rawPath))
	return claimsFolder + "/" + hex.EncodeToString(sum[:])
}

// heldClaim is a claim this device made. The token is a folder inside it, which proves the
// claim at that path is still this one.
type heldClaim struct {
	path  string
	token string
	// taken keeps Go's monotonic clock, which stops during sleep, so wallTaken is checked
	// too. A device that slept through its hold limit must notice.
	taken     time.Time
	wallTaken time.Time
}

func (h heldClaim) tokenPath() string {
	return h.path + "/" + h.token
}

func (h heldClaim) expired() bool {
	return time.Since(h.taken) >= claimHoldLimit || time.Since(h.wallTaken) >= claimHoldLimit
}

// stillOwned is the last check before a commit. A claim taken over, or held too long, must
// not commit, so the caller gives up and starts again.
func (h heldClaim) stillOwned(ctx context.Context, server rawServer) error {
	if h.expired() {
		return errClaimLost
	}
	if _, err := server.statRaw(ctx, h.tokenPath()); err != nil {
		if classify(err).Kind == "notFound" {
			return errClaimLost
		}
		return err
	}
	return nil
}

// acquireClaim takes the claim for a path, waiting if a peer holds it.
func acquireClaim(ctx context.Context, server rawServer, rawPath string) (heldClaim, error) {
	return acquireClaimFolder(ctx, server, claimPath(rawPath))
}

// acquireClaimFolder takes a claim by creating its folder, and takes over one abandoned by a
// device that died. Abandoned claims are rare, so the first second is spent just waiting.
func acquireClaimFolder(ctx context.Context, server rawServer, claim string) (heldClaim, error) {
	started := time.Now()
	nextStaleCheck := started.Add(time.Second)
	for {
		if err := ctx.Err(); err != nil {
			return heldClaim{}, err
		}
		created, err := createSettled(ctx, server, claim)
		if err != nil {
			return heldClaim{}, err
		}
		if created {
			return signClaim(ctx, server, claim)
		}
		if time.Now().After(nextStaleCheck) {
			takeOverIfStale(ctx, server, claim)
			nextStaleCheck = time.Now().Add(staleCheckEvery)
		}
		if time.Since(started) > claimWait {
			return heldClaim{}, errClaimBusy
		}
		select {
		case <-ctx.Done():
			return heldClaim{}, ctx.Err()
		case <-time.After(claimRetry):
		}
	}
}

// createSettled sees a claim's request through, so one abandoned on its way to the server can't
// leave a claim nobody knows they hold.
func createSettled(ctx context.Context, server rawServer, rawPath string) (bool, error) {
	creating, cancel := settled(ctx)
	defer cancel()
	return server.createExclusive(creating, rawPath)
}

// signClaim marks a new claim as this holder's. Nothing can take it over in the moment
// before the token exists, because a claim is only taken over when it's old.
func signClaim(ctx context.Context, server rawServer, claim string) (heldClaim, error) {
	now := time.Now()
	held := heldClaim{path: claim, token: uuid.NewString(), taken: now, wallTaken: now.Round(0)}
	if _, err := createSettled(ctx, server, held.tokenPath()); err != nil {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.remove(cleanup, claim, true)
		return heldClaim{}, err
	}
	return held, nil
}

// serverNow reads the server's clock from a new folder's timestamp, because a device with a
// wrong clock must never take over a live claim.
func serverNow(ctx context.Context, server rawServer) (time.Time, error) {
	return serverNowAt(ctx, server, claimsFolder+"/now-"+uuid.NewString())
}

// serverNowAt is serverNow with its scratch folder at a given name, for a drive that writes
// nothing in the control folder.
func serverNowAt(ctx context.Context, server rawServer, probe string) (time.Time, error) {
	if _, err := server.createExclusive(ctx, probe); err != nil {
		return time.Time{}, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.remove(cleanup, probe, true)
	}()
	entry, err := server.statRaw(ctx, probe)
	if err != nil {
		return time.Time{}, err
	}
	if entry.Modified.IsZero() {
		return time.Time{}, errors.New("the server gave no timestamp")
	}
	return entry.Modified, nil
}

// takeOverIfStale removes an abandoned claim. A move is atomic on its source, so only one
// device can win the takeover, and the rest simply retry. If the claim at this path changed
// since it was checked, its new owner finds its token gone and gives up, which is safe.
func takeOverIfStale(ctx context.Context, server rawServer, claim string) {
	entry, err := server.statRaw(ctx, claim)
	if err != nil || entry.Modified.IsZero() {
		return
	}
	now, err := serverNow(ctx, server)
	if err != nil || now.Sub(entry.Modified) < claimStaleAfter {
		return
	}
	// A peer may have retired it and a new holder taken the path while this was looking, and
	// moving that fresh claim would throw its owner out.
	if again, err := server.statRaw(ctx, claim); err != nil || !again.Modified.Equal(entry.Modified) {
		return
	}
	retired := claimsFolder + "/stale-" + uuid.NewString()
	if server.moveRaw(ctx, claim, retired, true, false) == nil {
		removeClaimFolder(ctx, server, retired)
	}
}

// removeClaimFolder deletes a claim and its token, whoever made them.
func removeClaimFolder(ctx context.Context, server rawServer, claim string) {
	entries, err := server.listRaw(ctx, claim)
	if err == nil {
		for _, entry := range entries {
			_ = server.remove(ctx, claim+"/"+entry.Name, true)
		}
	}
	_ = server.remove(ctx, claim, true)
}

// releaseClaim gives up a claim. Past the hold limit it does nothing, because the path might
// by then belong to someone else. An abandoned claim is cleared by the next takeover.
func releaseClaim(server rawServer, held heldClaim) {
	if held.expired() {
		return
	}
	// Runs even if the call was cancelled, so a cancelled save can't leave a claim behind.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// A claim left behind blocks this file for 10 minutes, so a brief failure gets retried.
	tokenGone := false
	for attempt := 1; attempt <= 3; attempt++ {
		var err error
		if !tokenGone {
			var found bool
			found, err = server.removeFound(ctx, held.tokenPath(), true)
			// No token means the path belongs to someone else now, and deleting a folder on
			// WebDAV takes everything in it, including their token.
			if err == nil && !found {
				return
			}
			tokenGone = err == nil
		}
		if err == nil {
			err = server.remove(ctx, held.path, true)
		}
		if err == nil || held.expired() {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(claimRetry):
		}
	}
}

// structureHeld reports whether a folder operation is under way, clearing an abandoned one.
func (d *drive) structureHeld(ctx context.Context) (bool, error) {
	_, err := d.server.statRaw(ctx, structureClaim)
	if err == nil {
		takeOverIfStale(ctx, d.server, structureClaim)
		return true, nil
	}
	if classify(err).Kind == "notFound" {
		return false, nil
	}
	return false, err
}

// withClaims holds the claims for several paths, in a fixed order so two devices can't
// deadlock, and stands aside for a folder operation. The body gets a check to run just
// before committing.
func (d *drive) withClaims(
	ctx context.Context, rawPaths []string, body func(stillHeld func() error) error,
) error {
	if d.unsafe {
		return d.withoutClaims(ctx, body)
	}
	sorted := slices.Clone(rawPaths)
	slices.Sort(sorted)
	sorted = slices.Compact(sorted)

	deadline := time.Now().Add(claimWait)
	for {
		var held []heldClaim
		release := func() {
			for _, claim := range held {
				releaseClaim(d.server, claim)
			}
		}
		for _, raw := range sorted {
			claim, err := acquireClaim(ctx, d.server, raw)
			if err != nil {
				release()
				return err
			}
			held = append(held, claim)
		}

		// A folder operation takes its claim before looking for file claims, and this
		// looks for its claim after taking ours, so at least one side sees the other.
		busy, err := d.structureHeld(ctx)
		if err != nil {
			release()
			return err
		}
		if !busy {
			err := d.checkVault(ctx, false)
			if err == nil {
				err = body(func() error {
					for _, claim := range held {
						if err := claim.stillOwned(ctx, d.server); err != nil {
							return err
						}
					}
					return nil
				})
			}
			if !errors.Is(err, errResultUnknown) {
				release()
			}
			return err
		}
		release()
		if time.Now().After(deadline) {
			return errClaimBusy
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(claimRetry):
		}
	}
}

// withStructure holds the structure claim for a folder move or trash, once no save is
// committing. A file claim can't protect a folder, because a save inside it claims a
// different path.
func (d *drive) withStructure(ctx context.Context, body func(stillHeld func() error) error) error {
	if d.unsafe {
		return d.withoutClaims(ctx, body)
	}
	held, err := acquireClaimFolder(ctx, d.server, structureClaim)
	if err != nil {
		return err
	}
	err = d.waitForFileClaims(ctx)
	if err == nil {
		err = d.checkVault(ctx, false)
	}
	if err == nil {
		err = body(func() error { return held.stillOwned(ctx, d.server) })
	}
	if !errors.Is(err, errResultUnknown) {
		releaseClaim(d.server, held)
	}
	return err
}

func isFileClaim(entry rawEntry) bool {
	return entry.IsDirectory && entry.Name != path.Base(structureClaim) &&
		!strings.HasPrefix(entry.Name, "stale-") && !strings.HasPrefix(entry.Name, "now-")
}

func (d *drive) waitForFileClaims(ctx context.Context) error {
	deadline := time.Now().Add(claimWait)
	for {
		entries, err := d.server.listRaw(ctx, claimsFolder)
		if err != nil {
			return err
		}
		claims := slices.DeleteFunc(entries, func(entry rawEntry) bool { return !isFileClaim(entry) })
		if len(claims) == 0 {
			return nil
		}
		now, err := serverNow(ctx, d.server)
		if err != nil {
			return err
		}
		live := slices.ContainsFunc(claims, func(entry rawEntry) bool {
			return entry.Modified.IsZero() || now.Sub(entry.Modified) < claimLiveFor
		})
		if !live {
			return nil
		}
		if time.Now().After(deadline) {
			return errClaimBusy
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(claimRetry):
		}
	}
}

// stagingName is a new staged file's name. It carries the time the upload began, because the
// file's modified time is the document's, which can be years old, and a file that looks old is
// swept away while its upload is still running.
func (d *drive) stagingName() string {
	if d.unsafe {
		return d.unsafeUploadName()
	}
	return fmt.Sprintf("%s/%s/%d-%s", stagingFolder, d.deviceID, time.Now().Unix(), uuid.NewString())
}

// stagingStarted reads back when a staged file's upload began.
func stagingStarted(name string) (time.Time, bool) {
	stamp, _, found := strings.Cut(name, "-")
	if !found {
		return time.Time{}, false
	}
	seconds, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(seconds, 0), true
}

// stageUpload streams a local file, encrypted if the drive is, to a raw name in the
// control folder. An interrupted upload only ever leaves a staging file behind.
func (d *drive) stageUpload(ctx context.Context, source string, counter *atomic.Int64) (string, error) {
	staged, _, err := d.stageUploadHashed(ctx, source, counter)
	return staged, err
}

// stageUploadHashed is stageUpload, and also returns the plain bytes' size and SHA-256, worked
// out as they stream past, so the file is read only once.
func (d *drive) stageUploadHashed(ctx context.Context, source string, counter *atomic.Int64) (string, stageInfo, error) {
	file, info, err := openPlainFile(source)
	if err != nil {
		return "", stageInfo{}, err
	}
	defer file.Close()

	hash := sha256.New()
	sent := &countedBytes{}
	var body io.Reader = io.TeeReader(countingReader{contextReader{ctx, localFile{file}}, counter}, io.MultiWriter(hash, sent))
	size := info.Size()
	if d.cipher != nil {
		if body, err = d.cipher.EncryptData(body); err != nil {
			return "", stageInfo{}, err
		}
		size = d.cipher.EncryptedSize(size)
	}

	staged := d.stagingName()
	objectInfo := object.NewStaticObjectInfo(staged, info.ModTime(), size, true, nil, d.plain)
	stored, err := d.plain.Put(ctx, body, objectInfo)
	if err == nil {
		err = d.checkStored(ctx, staged, stored, size)
	}
	if err != nil {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = d.server.remove(cleanup, staged, false)
		return "", stageInfo{}, err
	}
	return staged, stageInfo{SHA256: hex.EncodeToString(hash.Sum(nil)), Size: sent.n, Modified: info.ModTime()}, nil
}

// countedBytes counts what passes through it.
type countedBytes struct{ n int64 }

func (c *countedBytes) Write(p []byte) (int, error) {
	c.n += int64(len(p))
	return len(p), nil
}

// checkStored makes sure the server kept everything that was sent. A server or proxy can answer
// success for an upload it cut short, and that file would then replace a good one. WebDAV's
// answer is read back from the server, so it costs nothing. SFTP's is asked for, because it may
// only repeat the size that was sent.
func (d *drive) checkStored(ctx context.Context, staged string, stored interface{ Size() int64 }, sent int64) error {
	size := int64(-1)
	if stored != nil {
		size = stored.Size()
	}
	if _, isSFTP := d.server.(*sftpServer); isSFTP || size < 0 {
		entry, err := d.server.statRaw(ctx, staged)
		if err != nil {
			return err
		}
		size = entry.Size
	}
	if size != sent {
		return fmt.Errorf("%w: %d of %d bytes", errShortUpload, size, sent)
	}
	return nil
}

// saveResult says how a save ended. With a conflict, the server's version kept the name
// and ours was stored under ConflictPath.
type saveResult struct {
	Item         remoteItem `json:"item"`
	ConflictPath string     `json:"conflictPath,omitempty"`
	// DetailsMissed says why the file was saved without its details, for the log.
	DetailsMissed string `json:"detailsMissed,omitempty"`
}

// flattenedSuffix ends the name macOS gives a package on a drive, as in Report.numbers.pkgf.
const flattenedSuffix = ".pkgf"

// conflictExtension is what a copy keeps at the end of its name. macOS rebuilds a package from
// its name, so a package's two extensions stay together.
func conflictExtension(name string) string {
	extension := path.Ext(name)
	if extension != flattenedSuffix {
		return extension
	}
	return path.Ext(strings.TrimSuffix(name, extension)) + extension
}

// conflictName builds a conflict copy's name, keeping the extension and shortening the
// stem so the encrypted name stays inside the server's limit.
func conflictName(name, device string, when time.Time, attempt int) string {
	extension := conflictExtension(name)
	stem := strings.TrimSuffix(name, extension)
	suffix := fmt.Sprintf(" (conflict from %s %s)", device, when.Format("2006-01-02"))
	if attempt > 1 {
		suffix = fmt.Sprintf(" (conflict from %s %s %d)", device, when.Format("2006-01-02"), attempt)
	}
	const limit = 140
	if room := limit - len(suffix) - len(extension); len(stem) > room && room > 0 {
		stem = strings.ToValidUTF8(stem[:room], "")
	}
	return stem + suffix + extension
}

func (d *drive) exists(ctx context.Context, p string) (remoteItem, bool, error) {
	item, err := d.serverStat(ctx, p)
	if err == nil {
		return item, true, nil
	}
	if classify(err).Kind == "notFound" {
		return remoteItem{}, false, nil
	}
	return remoteItem{}, false, err
}

func (d *drive) ensureParent(ctx context.Context, p string) error {
	parent := path.Dir(p)
	if parent == "." {
		return nil
	}
	err := d.f.Mkdir(ctx, parent)
	if err != nil && classify(err).Kind == "forbidden" {
		// Two devices making the same folder: see alreadyMade.
		if _, found, statErr := d.exists(ctx, parent); statErr == nil && found {
			return nil
		}
	}
	return err
}

// sameContent reports whether the server's file is byte for byte the local one. When macOS
// replays a save after a crash, this device's own earlier save is at the target, and that
// must not turn into a conflict. It's also how a rebuilt database adopts what's on the server.
func (d *drive) sameContent(ctx context.Context, source, p string, remote remoteItem) (bool, error) {
	info, err := os.Stat(source)
	if err != nil {
		return false, err
	}
	if remote.IsDirectory || info.Size() != remote.Size {
		return false, nil
	}
	file, err := os.Open(source)
	if err != nil {
		return false, err
	}
	defer file.Close()
	local := sha256.New()
	if _, err := io.Copy(local, contextReader{ctx, file}); err != nil {
		return false, err
	}

	object, err := d.f.NewObject(ctx, p)
	if err != nil {
		return false, err
	}
	in, err := object.Open(ctx)
	if err != nil {
		return false, err
	}
	defer in.Close()
	server := sha256.New()
	if _, err := io.Copy(server, contextReader{ctx, in}); err != nil {
		return false, err
	}
	return bytes.Equal(local.Sum(nil), server.Sum(nil)), nil
}

// save stores a local file, keeping both versions if a peer saved first.
func (d *drive) save(
	ctx context.Context, source, p, baseVersion string, counter *atomic.Int64,
) (saveResult, error) {
	return d.saveFile(ctx, source, p, baseVersion, false, counter)
}

// saveFile stores a local file. baseVersion is the version this edit started from, as macOS
// reported it, and is empty for a new file or when no version is agreed. Nothing on the
// server is ever replaced unless it's exactly that version. With failOnConflict, a peer's
// version is reported as an error, and macOS merges instead of a conflict copy being made.
func (d *drive) saveFile(
	ctx context.Context, source, p, baseVersion string, failOnConflict bool, counter *atomic.Int64,
) (saveResult, error) {
	p = cleanPath(p)
	if err := d.checkName(p); err != nil {
		return saveResult{}, err
	}
	if d.server == nil {
		item, err := d.upload(ctx, source, p, counter)
		return saveResult{Item: item}, err
	}

	// The upload happens with no claim held, so a large file can't block anyone.
	staged, err := d.stage(ctx, source, counter)
	if err != nil {
		return saveResult{}, err
	}
	return d.commitStageWith(ctx, staged.Staged, source, p, baseVersion, failOnConflict, counter, fileInput{})
}

// stagedUpload is an upload waiting to be committed. A long upload can outlast a folder move, so
// the caller works out where the file belongs once this is done.
type stagedUpload struct {
	Staged string `json:"staged"`
	// The plain bytes as staging read them, for the file's details.
	SHA256     string `json:"sha256,omitempty"`
	Size       int64  `json:"size"`
	ModifiedNS int64  `json:"modifiedNs,omitempty"`
}

func (d *drive) stage(ctx context.Context, source string, counter *atomic.Int64) (stagedUpload, error) {
	if d.server == nil {
		return stagedUpload{}, nil
	}
	staged, info, err := d.stageUploadHashed(ctx, source, counter)
	if err != nil {
		return stagedUpload{}, err
	}
	d.staged.Store(staged, info)
	return stagedUpload{Staged: staged, SHA256: info.SHA256, Size: info.Size, ModifiedNS: info.Modified.UnixNano()}, nil
}

func (d *drive) discardStage(staged string) {
	if d.server == nil || staged == "" {
		return
	}
	d.staged.Delete(staged)
	cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = d.server.remove(cleanup, staged, false)
}

// commitStage puts a staged upload in place, and always clears it afterwards.
func (d *drive) commitStage(
	ctx context.Context, staged, source, p, baseVersion string, failOnConflict bool, counter *atomic.Int64,
) (saveResult, error) {
	return d.commitStageWith(ctx, staged, source, p, baseVersion, failOnConflict, counter, fileInput{})
}

// commitStageWith is commitStage, with what the saving device knows about the file for its
// details. Those never decide anything about the save itself.
func (d *drive) commitStageWith(
	ctx context.Context, staged, source, p, baseVersion string, failOnConflict bool, counter *atomic.Int64,
	input fileInput,
) (saveResult, error) {
	if staged == "" {
		return d.saveFile(ctx, source, p, baseVersion, failOnConflict, counter)
	}
	var info stageInfo
	if known, ok := d.staged.Load(staged); ok {
		info, _ = known.(stageInfo)
	}
	defer d.discardStage(staged)
	p = cleanPath(p)
	if err := d.checkName(p); err != nil {
		return saveResult{}, err
	}
	// Asked before any claim is taken: the first time, it checks the server on a scratch file.
	keeps := d.keepsDetails(ctx)

	raw := d.rawFile(p)
	for attempt := 1; ; attempt++ {
		var result saveResult
		var peerVersion *remoteItem
		err := d.withClaims(ctx, []string{raw}, func(stillHeld func() error) error {
			current, found, err := d.exists(ctx, p)
			if err != nil {
				return err
			}
			// An empty ID means no evidence, and that's never a match.
			if found && (baseVersion == "" || current.Version != baseVersion) {
				peerVersion = &current
				return nil
			}
			if found {
				if err := d.distinguish(ctx, staged, current); err != nil {
					return err
				}
				d.keepReplaced(ctx, p, raw, current)
			} else if err := d.ensureParent(ctx, p); err != nil {
				// Not found with a base means a peer deleted it, and our edit is put back.
				return err
			}
			if err := stillHeld(); err != nil {
				return err
			}
			// Only a name that's taken is replaced. Overwrite on Apache removes the old file first,
			// and on a free name it would replace anything another tool put there meanwhile.
			if err := d.commitMove(ctx, staged, raw, false, found); err != nil {
				if !found {
					// Something took the name after the check. It keeps it, as a peer's save would.
					if arrived, taken, statErr := d.exists(ctx, p); statErr == nil && taken {
						peerVersion = &arrived
						return nil
					}
				}
				return err
			}
			// The file is in place, so this is reported even if the save was cancelled meanwhile.
			// Otherwise the next save of the same edit meets it as a peer's version.
			checking, cancel := settled(ctx)
			defer cancel()
			item, entry, err := d.serverStatEntry(checking, p)
			if err != nil {
				return err
			}
			// Still under the claim, so no peer's save lands between the stat and the details.
			var previous *knownDetails
			if found {
				previous = current.details
			}
			missed := d.describeFile(checking, p, &item, entry, input, info, previous, keeps)
			result = saveResult{Item: item, DetailsMissed: missed}
			return nil
		})
		if errors.Is(err, errClaimLost) && attempt < commitAttempts {
			continue
		}
		if err != nil {
			return saveResult{}, err
		}
		if peerVersion == nil {
			return result, nil
		}
		// A failure here only means a conflict copy that wasn't needed, which is safe. The version
		// is read again after comparing, so what's reported is what was compared.
		if same, err := d.sameContent(ctx, source, p, *peerVersion); err == nil && same {
			if adopted, found, err := d.exists(ctx, p); err == nil && found && adopted.Version == peerVersion.Version {
				// A replay of a save whose reply was lost: the file landed, its details may not have.
				if keeps && adopted.SHA256 == "" && adopted.OwnModifiedNS == 0 {
					d.describeAdopted(ctx, p, &adopted, input, info)
				}
				return saveResult{Item: adopted}, nil
			}
		}
		if failOnConflict {
			return saveResult{}, errPeerChanged
		}
		// Claims are never nested, so the target's was released before taking this one.
		conflict, err := d.placeConflictCopy(ctx, staged, p, input, info, keeps)
		if err != nil {
			return saveResult{}, err
		}
		return saveResult{Item: *peerVersion, ConflictPath: conflict}, nil
	}
}

// keepReplaced copies the version a save is about to replace into the trash, where it can be
// restored for a week. Neither server can refuse a request from a device that lost its claim, and
// other tools don't use claims at all, so this is what makes an overwrite recoverable whatever
// caused it. It's only a second chance: if it fails, the save carries on, as it would without it.
func (d *drive) keepReplaced(ctx context.Context, p, raw string, current remoteItem) {
	if d.unsafe {
		// Unsafe mode keeps no trash, which is what a person chose it for.
		return
	}
	keeping, cancel := context.WithTimeout(ctx, keepCopyLimit)
	defer cancel()
	entry := trashFolder + "/" + versionPrefix + uuid.NewString()
	err := d.server.ensureFolder(keeping, entry)
	if err == nil {
		var meta []byte
		meta, err = json.Marshal(trashEntry{OriginalPath: p, DeletedAt: time.Now().Unix(), Device: d.deviceName})
		if err == nil {
			err = d.writeControlFile(keeping, entry+"/meta", meta)
		}
	}
	if err == nil {
		err = d.server.keepCopy(keeping, raw, entry+"/item", current.Size)
	}
	if err != nil {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		_ = d.server.removeAll(cleanup, entry)
	}
}

// describeAdopted gives details to a file a replayed save found already in place. It takes the
// file's claim and checks the version again, so it can never describe a peer's newer save.
func (d *drive) describeAdopted(ctx context.Context, p string, adopted *remoteItem, input fileInput, info stageInfo) {
	_ = d.withClaims(ctx, []string{d.rawFile(p)}, func(func() error) error {
		item, entry, err := d.serverStatEntry(ctx, p)
		if err != nil || item.Version != adopted.Version {
			return err
		}
		if d.describeFile(ctx, p, &item, entry, input, info, nil, true) == "" {
			*adopted = item
		}
		return nil
	})
}

func (d *drive) placeConflictCopy(
	ctx context.Context, staged, p string, input fileInput, info stageInfo, keeps bool,
) (string, error) {
	dir, name := path.Dir(p), path.Base(p)
	for attempt := 1; attempt <= 50; attempt++ {
		candidate := path.Join(dir, conflictName(name, d.deviceName, time.Now(), attempt))
		if strings.HasPrefix(candidate, "./") {
			candidate = strings.TrimPrefix(candidate, "./")
		}
		if _, found, err := d.exists(ctx, candidate); err != nil {
			return "", err
		} else if found {
			continue
		}
		var moved bool
		err := d.withClaims(ctx, []string{d.rawFile(candidate)}, func(stillHeld func() error) error {
			if _, found, err := d.exists(ctx, candidate); err != nil || found {
				return err
			}
			if err := d.ensureParent(ctx, candidate); err != nil {
				return err
			}
			if err := stillHeld(); err != nil {
				return err
			}
			if err := d.commitMove(ctx, staged, d.rawFile(candidate), false, false); err != nil {
				return err
			}
			moved = true
			// A conflict copy keeps the file's own dates too. Failing that only costs its details.
			if item, entry, err := d.serverStatEntry(ctx, candidate); err == nil {
				d.describeFile(ctx, candidate, &item, entry, input, info, nil, keeps)
			}
			return nil
		})
		if err != nil {
			return "", err
		}
		if moved {
			return candidate, nil
		}
	}
	return "", errors.New("couldn't find a free name for the conflict copy")
}

// trashEntry is the metadata kept beside a deleted item, encrypted on an encrypted drive.
type trashEntry struct {
	OriginalPath string `json:"originalPath"`
	DeletedAt    int64  `json:"deletedAt"`
	Device       string `json:"device"`
}

// errPeerChanged means a delete was refused, because the item isn't the version this
// device last saw and removing it would trash a peer's edit unseen.
var errPeerChanged = errors.New("this item changed on the server")

// trash moves an item to the server's trash. The metadata is written first, so a crash
// can leave an empty entry but never a deleted item nobody can restore.
func (d *drive) trash(ctx context.Context, p, baseVersion string) error {
	p = cleanPath(p)
	if d.server == nil {
		return d.remove(ctx, p)
	}
	item, found, err := d.exists(ctx, p)
	if err != nil || !found {
		return err
	}
	raw := d.rawFile(p)
	if item.IsDirectory {
		return d.withStructure(ctx, func(stillHeld func() error) error {
			if _, found, err := d.exists(ctx, p); err != nil || !found {
				return err
			}
			return d.moveToTrash(ctx, p, raw, true, stillHeld)
		})
	}
	return d.withClaims(ctx, []string{raw}, func(stillHeld func() error) error {
		current, found, err := d.exists(ctx, p)
		if err != nil || !found {
			return err
		}
		if current.Version != baseVersion {
			return errPeerChanged
		}
		return d.moveToTrash(ctx, p, raw, false, stillHeld)
	})
}

func (d *drive) moveToTrash(
	ctx context.Context, p, raw string, folder bool, stillHeld func() error,
) error {
	if d.unsafe {
		return d.removeForGood(ctx, raw, folder)
	}
	entry := trashFolder + "/" + uuid.NewString()
	if err := d.server.ensureFolder(ctx, entry); err != nil {
		return err
	}
	meta, err := json.Marshal(trashEntry{
		OriginalPath: p, DeletedAt: time.Now().Unix(), Device: d.deviceName,
	})
	if err != nil {
		return err
	}
	if err := d.writeControlFile(ctx, entry+"/meta", meta); err != nil {
		return err
	}
	if err := stillHeld(); err != nil {
		return err
	}
	return d.commitMove(ctx, raw, entry+"/item", folder, false)
}

// writeControlFile stores a small file in the control folder, encrypted if the drive is.
func (d *drive) writeControlFile(ctx context.Context, remote string, content []byte) error {
	var body io.Reader = bytes.NewReader(content)
	size := int64(len(content))
	if d.cipher != nil {
		var err error
		if body, err = d.cipher.EncryptData(body); err != nil {
			return err
		}
		size = d.cipher.EncryptedSize(size)
	}
	info := object.NewStaticObjectInfo(remote, time.Now(), size, true, nil, d.plain)
	_, err := d.plain.Put(ctx, body, info)
	return err
}

// publishControlFile replaces a control file in one step, so nobody can read half of it.
func (d *drive) publishControlFile(ctx context.Context, remote string, content []byte) error {
	if d.server == nil {
		return d.writeControlFile(ctx, remote, content)
	}
	staged := d.stagingName()
	if err := d.writeControlFile(ctx, staged, content); err != nil {
		return err
	}
	defer d.discardStage(staged)
	return d.server.moveRaw(ctx, staged, remote, false, true)
}

// moveItem renames or moves an item, refusing to replace anything at the destination.
// baseVersion is the version macOS last saw, which is how a replay recognises its own result.
func (d *drive) moveItem(ctx context.Context, source, destination, baseVersion string) (remoteItem, error) {
	source, destination = cleanPath(source), cleanPath(destination)
	if err := d.checkName(destination); err != nil {
		return remoteItem{}, err
	}
	if d.server == nil {
		if err := d.move(ctx, source, destination); err != nil {
			return remoteItem{}, err
		}
		return d.stat(ctx, destination)
	}
	item, found, err := d.exists(ctx, source)
	if err != nil {
		return remoteItem{}, err
	}
	if !found {
		// A replay after a lost response finds the move already done. But a source that's gone
		// proves nothing about what's at the destination: a peer can have deleted one and
		// created the other. Only a matching version proves it's this item. A folder has no
		// version, but it's the same kind at the same name.
		if moved, done, err := d.exists(ctx, destination); err == nil && done {
			if moved.IsDirectory || (baseVersion != "" && moved.Version == baseVersion) {
				return moved, nil
			}
		}
		return remoteItem{}, statusError(http.StatusNotFound)
	}
	if source == destination {
		return item, nil
	}

	rawSource, rawDestination := d.rawFile(source), d.rawFile(destination)
	var moved remoteItem
	move := func(stillHeld func() error) error {
		if _, found, err := d.exists(ctx, destination); err != nil {
			return err
		} else if found {
			return errNameTaken
		}
		if err := d.ensureParent(ctx, destination); err != nil {
			return err
		}
		if err := stillHeld(); err != nil {
			return err
		}
		if err := d.commitMove(ctx, rawSource, rawDestination, item.IsDirectory, false); err != nil {
			// Something took the name after the check, and the move refused to replace it.
			if _, taken, statErr := d.exists(ctx, destination); statErr == nil && taken && !errors.Is(err, errResultUnknown) {
				return errNameTaken
			}
			return err
		}
		// It moved, so that's reported even if the call was cancelled meanwhile.
		checking, cancel := settled(ctx)
		defer cancel()
		moved, err = d.serverStat(checking, destination)
		return err
	}
	if item.IsDirectory {
		err = d.withStructure(ctx, move)
	} else {
		err = d.withClaims(ctx, []string{rawSource, rawDestination}, move)
	}
	return moved, err
}
