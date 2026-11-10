// Apache 2 license - developer@infinitecontext.com

package main

// File details are what a file was on the device that saved it: its own dates, its checksum, and
// what kind of thing it is. WebDAV servers date a file when it arrives, and refuse to set that
// date, so the details live beside the file as a WebDAV property of our own. A property is kept
// apart from the file, so writing one never touches the file's bytes, size, date or ETag. Each
// drive checks that once on a scratch file before any file gets one. Nothing needed to read or
// decrypt a file is ever in a property: losing one costs dates and a check, never the file.

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/rclone/rclone/backend/webdav/api"
)

const (
	detailsNamespace = "https://infinitecontext.com/ns/cloudaccess/"
	// detailsFormat goes up only when a field changes meaning. Adding a field never bumps it.
	detailsFormat = 1
	// maxDetailsBytes is the most written. Stock Apache keeps properties in SDBM records of about
	// 1 KB, and refuses a bigger value with a 500.
	maxDetailsBytes = 900
	// maxDetailsReadBytes is the most read. A larger value is ignored, and the item listed as today.
	maxDetailsReadBytes = 8 << 10
	// detailsCheckFile says whether this drive's server keeps details without touching files.
	detailsCheckFile = controlFolder + "/file-details.json"
	bundleStoredAs   = "apple-flattened-package"
	// maxBundleType is a long type identifier. Real ones are under 60 characters, and this keeps an
	// encrypted package's details under what stock Apache keeps.
	maxBundleType = 128
)

// errDetailsRefused means the server didn't keep a property. The save it belongs to still stands.
var errDetailsRefused = errors.New("the server didn't keep this file's details")

// errDetailsTooBig means the details wouldn't fit what the server is known to keep.
var errDetailsTooBig = errors.New("this file's details are too big to keep on the server")

// errFileDamaged means a download didn't match the checksum its details recorded.
var errFileDamaged = errors.New("this file didn't arrive as it was saved")

// detailsKeeper is a server that can keep a property beside a file. Only WebDAV can.
type detailsKeeper interface {
	setDetails(ctx context.Context, rawPath string, folder bool, value string) error
	// statWithDetails asks for details even in the control folder, where listings don't.
	statWithDetails(ctx context.Context, rawPath string) (rawEntry, error)
}

type detailsEncryption struct {
	Type     string `json:"type"`
	Vault    string `json:"vault,omitempty"`
	Revision int    `json:"revision,omitempty"`
}

// detailsVersion is the server version a file's content details describe. Another tool writing
// over the file changes its ETag and leaves the old property behind, so a mismatch means stale.
type detailsVersion struct {
	ETag       string `json:"etag"`
	StoredSize int64  `json:"storedSize"`
}

type detailsBundle struct {
	StoredAs string `json:"storedAs"`
	Type     string `json:"type,omitempty"`
}

// detailsContent describes these exact bytes, and is written new on every save.
type detailsContent struct {
	Modified  string         `json:"modified,omitempty"`
	Size      int64          `json:"size"`
	SHA256    string         `json:"sha256,omitempty"`
	Bundle    *detailsBundle `json:"bundle,omitempty"`
	Describes detailsVersion `json:"describes"`
}

// detailsBody is what an encrypted drive seals, so the server learns nothing new.
type detailsBody struct {
	Content   *detailsContent `json:"content,omitempty"`
	Item      json.RawMessage `json:"item,omitempty"`
	WrittenBy string          `json:"writtenBy,omitempty"`
}

// fileDetails is the property's JSON. Fields it doesn't know are ignored, at any depth.
type fileDetails struct {
	Format     int               `json:"format"`
	Kind       string            `json:"kind"`
	Encryption detailsEncryption `json:"encryption"`
	Content    *detailsContent   `json:"content,omitempty"`
	// Item belongs to the file across all its saves, and is carried forward word for word.
	Item      json.RawMessage `json:"item,omitempty"`
	Sealed    string          `json:"sealed,omitempty"`
	WrittenBy string          `json:"writtenBy,omitempty"`
}

// knownDetails is what a listing understood from a property that passed every check.
type knownDetails struct {
	Kind       string
	Modified   time.Time // zero when the content details were stale or absent
	Created    time.Time
	SHA256     string
	BundleType string
	// Item is kept for carrying forward when a save replaces the file.
	Item json.RawMessage
	// Length is how big the value was, which this server is then known to keep.
	Length int
}

// fileInput is what the saving device knows about a file.
type fileInput struct {
	Modified   time.Time
	Created    time.Time
	BundleType string
}

// stageInfo is what staging learned about the bytes it sent.
type stageInfo struct {
	SHA256   string
	Size     int64
	Modified time.Time
}

// readDetails checks a property read from the server, which is untrusted. Anything that fails is
// dropped, and the item is listed as it would be without details.
func (d *drive) readDetails(entry rawEntry) (knownDetails, bool) {
	value := entry.Details
	if value == "" || len(value) > maxDetailsReadBytes {
		return knownDetails{}, false
	}
	var outer fileDetails
	if err := json.Unmarshal([]byte(value), &outer); err != nil {
		return knownDetails{}, false
	}
	if outer.Format < 1 || outer.Format > detailsFormat {
		return knownDetails{}, false
	}
	switch outer.Kind {
	case "folder":
		if !entry.IsDirectory {
			return knownDetails{}, false
		}
	case "file", "bundle":
		if entry.IsDirectory {
			return knownDetails{}, false
		}
	default:
		return knownDetails{}, false
	}
	body := detailsBody{Content: outer.Content, Item: outer.Item, WrittenBy: outer.WrittenBy}
	if d.cipher == nil {
		if outer.Encryption.Type != "none" || outer.Sealed != "" {
			return knownDetails{}, false
		}
	} else {
		// The vault marker stays the only authority on how to decrypt. Details from another drive,
		// or from a vault newer than the one this device trusts, aren't this drive's.
		if outer.Encryption.Type != "rclone-crypt" || d.vault == nil ||
			outer.Encryption.Vault != d.vault.id || outer.Encryption.Revision > d.vaultRevision() {
			return knownDetails{}, false
		}
		opened, err := d.unseal(outer.Sealed)
		if err != nil {
			return knownDetails{}, false
		}
		body = opened
	}
	known := knownDetails{Kind: outer.Kind, Item: body.Item, Length: len(value)}
	if created, ok := itemCreated(body.Item); ok {
		known.Created = created
	}
	if content := body.Content; content != nil && !entry.IsDirectory && d.contentDescribes(content, entry) {
		if modified, ok := parseDetailsTime(content.Modified); ok {
			known.Modified = modified
		}
		if isSHA256(content.SHA256) {
			known.SHA256 = content.SHA256
		}
		if bundle := content.Bundle; outer.Kind == "bundle" && bundle != nil && bundle.StoredAs == bundleStoredAs &&
			len(bundle.Type) <= maxBundleType {
			known.BundleType = bundle.Type
		}
	}
	return known, true
}

// contentDescribes reports whether content details belong to the version on the server now.
func (d *drive) contentDescribes(content *detailsContent, entry rawEntry) bool {
	if entry.ETag == "" || normalizeETag(content.Describes.ETag) != entry.ETag || content.Describes.StoredSize != entry.Size {
		return false
	}
	plain := entry.Size
	if d.cipher != nil {
		var err error
		if plain, err = d.cipher.DecryptedSize(entry.Size); err != nil {
			return false
		}
	}
	return content.Size == plain
}

// encodeDetails builds a property value. limit is the most this server is known to keep.
func (d *drive) encodeDetails(kind string, content *detailsContent, item json.RawMessage, limit int) (string, error) {
	outer := fileDetails{Format: detailsFormat, Kind: kind}
	body := detailsBody{Content: content, Item: item, WrittenBy: d.appName}
	if d.cipher == nil {
		outer.Encryption = detailsEncryption{Type: "none"}
		outer.Content, outer.Item, outer.WrittenBy = body.Content, body.Item, body.WrittenBy
	} else {
		if d.vault == nil {
			return "", errors.New("an encrypted drive without its vault can't describe a file")
		}
		outer.Encryption = detailsEncryption{Type: "rclone-crypt", Vault: d.vault.id, Revision: d.vaultRevision()}
		sealed, err := d.seal(body)
		if err != nil {
			return "", err
		}
		outer.Sealed = sealed
	}
	encoded, err := json.Marshal(outer)
	if err != nil {
		return "", err
	}
	if len(encoded) > max(limit, maxDetailsBytes) {
		return "", errDetailsTooBig
	}
	return string(encoded), nil
}

// seal encrypts details with the drive's own cipher, which authenticates them.
func (d *drive) seal(body detailsBody) (string, error) {
	plain, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	encrypted, err := d.cipher.EncryptData(bytes.NewReader(plain))
	if err != nil {
		return "", err
	}
	sealed, err := io.ReadAll(encrypted)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(sealed), nil
}

func (d *drive) unseal(sealed string) (detailsBody, error) {
	if sealed == "" || len(sealed) > maxDetailsReadBytes {
		return detailsBody{}, errors.New("no sealed details")
	}
	encrypted, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		return detailsBody{}, err
	}
	decrypted, err := d.cipher.DecryptData(io.NopCloser(bytes.NewReader(encrypted)))
	if err != nil {
		return detailsBody{}, err
	}
	defer decrypted.Close()
	plain, err := io.ReadAll(io.LimitReader(decrypted, maxDetailsReadBytes))
	if err != nil {
		return detailsBody{}, err
	}
	var body detailsBody
	if err := json.Unmarshal(plain, &body); err != nil {
		return detailsBody{}, err
	}
	return body, nil
}

// mergeItem carries the old item forward word for word, fields this build doesn't know included,
// and adds what it knows only where the old one says nothing. A creation date already recorded
// wins, because a Mac that didn't have the file's details may report when it first downloaded it.
func mergeItem(old json.RawMessage, created time.Time) json.RawMessage {
	fields := map[string]json.RawMessage{}
	if len(old) > 0 {
		if err := json.Unmarshal(old, &fields); err != nil {
			fields = map[string]json.RawMessage{}
		}
	}
	if _, recorded := fields["created"]; !recorded && !created.IsZero() {
		if stamp, err := json.Marshal(created.UTC().Format(time.RFC3339Nano)); err == nil {
			fields["created"] = stamp
		}
	}
	if len(fields) == 0 {
		return nil
	}
	merged, err := json.Marshal(fields)
	if err != nil {
		return nil
	}
	return merged
}

func itemCreated(item json.RawMessage) (time.Time, bool) {
	if len(item) == 0 {
		return time.Time{}, false
	}
	var fields struct {
		Created string `json:"created"`
	}
	if err := json.Unmarshal(item, &fields); err != nil {
		return time.Time{}, false
	}
	return parseDetailsTime(fields.Created)
}

// parseDetailsTime accepts only a date that could be real: after 1970 and no later than a day
// from now, which allows for a clock that's a little ahead.
func parseDetailsTime(value string) (time.Time, bool) {
	if value == "" {
		return time.Time{}, false
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil || !parsed.After(time.Unix(0, 0)) || parsed.After(time.Now().Add(24*time.Hour)) {
		return time.Time{}, false
	}
	return parsed, true
}

func isSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && strings.ToLower(value) == value
}

// applyDetails puts what's known into an item for Swift. The server's own date stays in
// ModifiedNS, because versions depend on it.
func (item *remoteItem) applyDetails(known knownDetails, keep bool) {
	item.Kind = known.Kind
	if !known.Modified.IsZero() {
		item.OwnModifiedNS = known.Modified.UnixNano()
	}
	if !known.Created.IsZero() {
		item.CreatedNS = known.Created.UnixNano()
	}
	item.SHA256 = known.SHA256
	item.BundleType = known.BundleType
	if keep {
		copied := known
		item.details = &copied
	}
}

// describeFile writes a file's details right after it was put in place, still under its claim,
// so no peer's save can land in between. The ETag is the one the stat after the move returned.
// It never fails the save: what went wrong is returned for the log.
func (d *drive) describeFile(
	ctx context.Context, p string, item *remoteItem, entry rawEntry, input fileInput, staged stageInfo,
	previous *knownDetails, keeps bool,
) string {
	keeper, ok := d.server.(detailsKeeper)
	if !ok || !keeps || entry.IsDirectory || entry.ETag == "" {
		return ""
	}
	modified := input.Modified
	if modified.IsZero() {
		modified = staged.Modified
	}
	content := &detailsContent{
		Size:      item.Size,
		SHA256:    staged.SHA256,
		Describes: detailsVersion{ETag: entry.ETag, StoredSize: entry.Size},
	}
	if !modified.IsZero() {
		content.Modified = modified.UTC().Format(time.RFC3339Nano)
	}
	// A hash of other bytes would make every later download fail its check.
	if staged.Size != item.Size {
		content.SHA256 = ""
	}
	kind := "file"
	if strings.HasSuffix(p, flattenedSuffix) {
		kind = "bundle"
		content.Bundle = &detailsBundle{StoredAs: bundleStoredAs}
		if len(input.BundleType) <= maxBundleType {
			content.Bundle.Type = input.BundleType
		}
	}
	var carried json.RawMessage
	limit := maxDetailsBytes
	if previous != nil {
		carried = previous.Item
		limit = previous.Length
	}
	value, err := d.encodeDetails(kind, content, mergeItem(carried, input.Created), limit)
	if err == nil {
		err = keeper.setDetails(ctx, d.rawFile(p), false, value)
	}
	if err != nil {
		return detailsFailure(err)
	}
	entry.Details = value
	if known, ok := d.readDetails(entry); ok {
		item.applyDetails(known, !d.readOnly)
	}
	return ""
}

// describeFolder records when a folder this device just made was created.
func (d *drive) describeFolder(ctx context.Context, raw string, created time.Time) {
	keeper, ok := d.server.(detailsKeeper)
	if !ok || created.IsZero() {
		return
	}
	if value, err := d.encodeDetails("folder", nil, mergeItem(nil, created), maxDetailsBytes); err == nil {
		_ = keeper.setDetails(ctx, raw, true, value)
	}
}

// detailsFailure names what went wrong, without any name or path, for the log.
func detailsFailure(err error) string {
	switch {
	case errors.Is(err, errDetailsTooBig):
		return "tooBig"
	case errors.Is(err, errDetailsRefused):
		return "refused"
	}
	if kind := classify(err).Kind; kind != "other" {
		return kind
	}
	return "failed"
}

// detailsCheck is shared by every device on a drive, so they all write details or none do.
type detailsCheck struct {
	Format  int   `json:"format"`
	Kept    bool  `json:"kept"`
	Checked int64 `json:"checked"`
}

// keepsDetails reports whether this drive's server has been shown to keep a property without
// touching the file it describes. The first device to ask checks, on a scratch file, and records
// the answer for every device. Anything uncertain means no, and is asked again next time.
func (d *drive) keepsDetails(ctx context.Context) bool {
	keeper, ok := d.server.(detailsKeeper)
	if !ok || d.readOnly {
		return false
	}
	d.detailsMu.Lock()
	defer d.detailsMu.Unlock()
	if d.detailsKnown {
		return d.detailsKept
	}
	content, err := d.readControlFile(ctx, detailsCheckFile)
	if err == nil {
		var check detailsCheck
		if json.Unmarshal(content, &check) != nil || check.Format != detailsFormat {
			return false
		}
		d.detailsKnown, d.detailsKept = true, check.Kept
		return check.Kept
	}
	if !isNotFound(err) {
		return false
	}
	kept, err := d.checkKeepsDetails(ctx, keeper)
	if err != nil {
		return false
	}
	encoded, err := json.Marshal(detailsCheck{Format: detailsFormat, Kept: kept, Checked: time.Now().Unix()})
	if err != nil {
		return false
	}
	// Written in place, not moved in from staging: saves are the only things that move files out
	// of staging, and a half-written answer can't be read, which counts as not known.
	if err := d.writeControlFile(ctx, detailsCheckFile, encoded); err != nil {
		return false
	}
	d.detailsKnown, d.detailsKept = true, kept
	return kept
}

// checkKeepsDetails writes a property on a scratch file and passes only if it reads back exactly,
// survives a move, and the file's bytes, size, date and ETag never changed. An error means the
// check couldn't finish, which is different from a server that failed it.
func (d *drive) checkKeepsDetails(ctx context.Context, keeper detailsKeeper) (bool, error) {
	scratch, moved := d.stagingName(), d.stagingName()
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = d.server.remove(cleanup, scratch, false)
		_ = d.server.remove(cleanup, moved, false)
	}()
	content := make([]byte, 256)
	if _, err := rand.Read(content); err != nil {
		return false, err
	}
	if err := d.writeControlFile(ctx, scratch, content); err != nil {
		return false, err
	}
	before, err := keeper.statWithDetails(ctx, scratch)
	if err != nil {
		return false, err
	}
	if before.ETag == "" {
		// With no ETag, details could never be tied to a version.
		return false, nil
	}
	value := fmt.Sprintf(`{"format":%d,"kind":"file","check":"%s"}`, detailsFormat, uuid.NewString())
	if err := keeper.setDetails(ctx, scratch, false, value); err != nil {
		if refusedDetails(err) {
			return false, nil
		}
		return false, err
	}
	after, err := keeper.statWithDetails(ctx, scratch)
	if err != nil {
		return false, err
	}
	if !unchanged(before, after) || after.Details != value {
		return false, nil
	}
	readBack, err := d.readControlFile(ctx, scratch)
	if err != nil {
		return false, err
	}
	if !bytes.Equal(readBack, content) {
		return false, nil
	}
	if err := d.server.moveRaw(ctx, scratch, moved, false, false); err != nil {
		return false, err
	}
	travelled, err := keeper.statWithDetails(ctx, moved)
	if err != nil {
		return false, err
	}
	return unchanged(before, travelled) && travelled.Details == value, nil
}

func unchanged(before, after rawEntry) bool {
	return after.ETag == before.ETag && after.Size == before.Size && after.Modified.Equal(before.Modified)
}

// refusedDetails tells a server that won't keep a property from one that couldn't answer now.
func refusedDetails(err error) bool {
	if errors.Is(err, errDetailsRefused) {
		return true
	}
	var davError *api.Error
	if errors.As(err, &davError) {
		switch davError.StatusCode {
		case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusServiceUnavailable,
			http.StatusBadGateway, http.StatusGatewayTimeout, http.StatusLocked:
			return false
		}
		return davError.StatusCode >= 400
	}
	return false
}
