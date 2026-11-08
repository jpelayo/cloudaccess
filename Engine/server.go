// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"path"
	"strings"
	"time"
)

// errNameTooLong means an item's encrypted name won't fit on the server. Crypt's base32
// names grow by about 60%, so a plain name of about 143 bytes reaches the usual limit.
var errNameTooLong = errors.New("this name is too long to store on an encrypted drive")

// maxServerNameBytes is the longest single name the servers we support accept.
const maxServerNameBytes = 255

const (
	// listingsAtOnce bounds the memory listings can take across every drive.
	listingsAtOnce = 4
)

var listingSlots = make(chan struct{}, listingsAtOnce)

// rawServer is what the commit layer needs from a server, beyond rclone's transfers. Paths
// are raw names on the server, relative to the drive's root, so encrypted drives pass
// encrypted names.
type rawServer interface {
	// createExclusive creates a folder, and any missing parents. It reports false if the
	// folder already exists. Of any number of devices trying at once, exactly one gets true,
	// which is what makes a claim a lock.
	createExclusive(ctx context.Context, rawPath string) (bool, error)
	// ensureFolder creates a control folder and its parents. An existing folder is fine.
	ensureFolder(ctx context.Context, rawPath string) error
	// remove deletes a file or an empty folder. A missing item is fine.
	remove(ctx context.Context, rawPath string, folder bool) error
	// removeFound is remove, and reports whether the item was really there.
	removeFound(ctx context.Context, rawPath string, folder bool) (bool, error)
	// removeAll deletes a folder and everything in it. A missing folder is fine.
	removeAll(ctx context.Context, rawPath string) error
	// moveRaw moves an item. With overwrite it replaces the destination. On SFTP that's one step,
	// but Apache removes the old file before moving the new one in, as RFC 4918 says, so for a
	// moment there's nothing at that name. Without overwrite, an existing destination is refused.
	moveRaw(ctx context.Context, from, to string, folder, overwrite bool) error
	// keepCopy makes a second copy of a file, leaving the file where it is.
	keepCopy(ctx context.Context, from, to string, size int64) error
	listRaw(ctx context.Context, rawPath string) ([]rawEntry, error)
	statRaw(ctx context.Context, rawPath string) (rawEntry, error)
}

// rawEntry is one item on the server, with its raw name.
type rawEntry struct {
	Name        string
	IsDirectory bool
	Size        int64
	Modified    time.Time
	ETag        string
	// Details is this app's own property, as the server sent it. Only WebDAV keeps one.
	Details string
}

// versionID turns a server's version evidence into a fixed-size ID. macOS stores it as the
// item's content version and hands it back as the base of an edit, and Apple limits that to
// 128 bytes, while an ETag can be any length. No evidence gives an empty ID, which never
// matches anything, so nothing is overwritten on a server that can't say what changed.
func versionID(etag string) string {
	if etag == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(etag))
	return hex.EncodeToString(sum[:])
}

func (d *drive) rawFolder(dir string) string {
	if d.cipher == nil || dir == "" {
		return dir
	}
	return d.cipher.EncryptDirName(dir)
}

func (d *drive) rawFile(file string) string {
	if d.cipher == nil {
		return file
	}
	return d.cipher.EncryptFileName(file)
}

// checkName refuses a path whose names won't fit on the server, before anything is sent.
func (d *drive) checkName(p string) error {
	for _, name := range strings.Split(d.rawFile(p), "/") {
		if len(name) > maxServerNameBytes {
			return errNameTooLong
		}
	}
	return nil
}

// itemFromRaw turns a raw entry into a plain-named item, or reports that it isn't ours.
func (d *drive) itemFromRaw(entry rawEntry, dir string) (remoteItem, bool) {
	name := entry.Name
	size := entry.Size
	if d.cipher != nil {
		var err error
		if entry.IsDirectory {
			name, err = d.cipher.DecryptDirName(name)
		} else {
			name, err = d.cipher.DecryptFileName(name)
			if err == nil {
				size, err = d.cipher.DecryptedSize(size)
			}
		}
		if err != nil {
			return remoteItem{}, false
		}
	}
	item := remoteItem{
		Path:        path.Join(dir, name),
		IsDirectory: entry.IsDirectory,
		Size:        size,
		Version:     versionID(entry.ETag),
	}
	if !entry.Modified.IsZero() {
		item.ModifiedNS = entry.Modified.UnixNano()
	}
	if known, ok := d.readDetails(entry); ok {
		// A read-only drive never saves, so it has nothing to carry forward.
		item.applyDetails(known, !d.readOnly)
	}
	return item, true
}

func (d *drive) serverList(ctx context.Context, dir string) ([]remoteItem, error) {
	// A listing holds a whole folder in memory several times over on its way to Swift, so only a
	// few run at once. A cancelled caller leaves the queue straight away.
	select {
	case listingSlots <- struct{}{}:
		defer func() { <-listingSlots }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	// Finder waits on this, so a server that stalls gives an error instead of a frozen window.
	waiting, cancel := context.WithTimeout(ctx, listingLimit)
	defer cancel()
	entries, err := d.server.listRaw(waiting, d.rawFolder(dir))
	if err != nil {
		if ctx.Err() == nil && errors.Is(waiting.Err(), context.DeadlineExceeded) {
			return nil, fmt.Errorf("%w: %v", errFolderTooSlow, err)
		}
		return nil, err
	}
	if err := checkListingSize(len(entries)); err != nil {
		return nil, err
	}
	items := make([]remoteItem, 0, len(entries))
	for _, entry := range entries {
		if entry.Name == controlFolder {
			continue
		}
		if item, ok := d.itemFromRaw(entry, dir); ok {
			items = append(items, item)
		}
	}
	return items, nil
}

func (d *drive) serverStat(ctx context.Context, p string) (remoteItem, error) {
	item, _, err := d.serverStatEntry(ctx, p)
	return item, err
}

// serverStatEntry is serverStat, with the raw entry it came from.
func (d *drive) serverStatEntry(ctx context.Context, p string) (remoteItem, rawEntry, error) {
	entry, err := d.server.statRaw(ctx, d.rawFile(p))
	if err != nil {
		return remoteItem{}, rawEntry{}, err
	}
	dir := path.Dir(p)
	if dir == "." {
		dir = ""
	}
	item, ok := d.itemFromRaw(entry, dir)
	if !ok {
		return remoteItem{}, rawEntry{}, errors.New("this item can't be decrypted")
	}
	return item, entry, nil
}

// versionStamper is a server whose versions can't tell two saves apart on their own. SFTP's
// are only a size and a time in whole seconds, so two same-size saves within a second match.
type versionStamper interface {
	// stampNewer gives an item a modified time later than the given one.
	stampNewer(ctx context.Context, rawPath string, than time.Time) error
}

// distinguish moves a staged file's time past the version it's replacing. Size and whole-second
// time are all the version SFTP has, so a time that only moves forward is what stops any version
// coming back. Comparing with the current one isn't enough: a version from two saves ago could
// return, and a device still holding it as its base would overwrite the save. This runs under
// the claim, so the two can't change while they're compared.
func (d *drive) distinguish(ctx context.Context, staged string, current remoteItem) error {
	stamper, ok := d.server.(versionStamper)
	if !ok {
		return nil
	}
	entry, err := d.server.statRaw(ctx, staged)
	if err != nil {
		return err
	}
	replaced := time.Unix(0, current.ModifiedNS)
	if entry.Modified.Unix() > replaced.Unix() {
		return nil
	}
	return stamper.stampNewer(ctx, staged, replaced)
}
