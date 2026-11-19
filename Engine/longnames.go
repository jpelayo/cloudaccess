// Apache 2 license - developer@infinitecontext.com

package main

// Long names on encrypted drives. rclone's crypt names grow by about 60%, so a name of about 143
// bytes or more doesn't fit the 255 bytes a server allows once encrypted, and accented letters
// count twice. Instead of refusing such a file, the server keeps a short form of its name: the
// start of the name, a tilde, a hash of the whole name, and the extension. It's a pure function
// of the full name, so every device picks the same server name, writes and replays need no
// lookup, and the short form is an ordinary name, encrypted as usual: plain rclone and a recovery
// kit still open the file, under a readable name with the right extension.
//
// The full name is kept in the item's file details, sealed like the rest, and shown only when it
// hashes back to the short form on the server, so a stale or copied one is ignored by itself.
// Where details don't exist (SFTP, Unsafe mode, a server that fails the details check, or a
// property that's lost) the item simply shows under its short form.

import (
	"context"
	"crypto/sha256"
	"encoding/base32"
	"encoding/json"
	"path"
	"regexp"
	"strings"
	"unicode/utf8"
)

const (
	// shortHashLength is how many base32 characters of the full name's SHA-256 a short form keeps:
	// 50 bits, far more than one folder's names could ever collide on.
	shortHashLength = 10
	// maxShortExtension is the longest extension a short form keeps, dot included.
	maxShortExtension = 16
)

// shortFormHash finds the hash in a short form: a tilde and the hash at the end, or before the
// extension.
var shortFormHash = regexp.MustCompile(`~([a-z2-7]{10})(\.[^./~]{1,15})?$`)

var lowerBase32 = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

// nameHash is the hash a short form carries for a full name.
func nameHash(full string) string {
	sum := sha256.Sum256([]byte(full))
	return lowerBase32.EncodeToString(sum[:])[:shortHashLength]
}

// fitsServer reports whether a name fits the server once encrypted. Every name fits a plain drive.
func (d *drive) fitsServer(name string) bool {
	if d.cipher == nil {
		return true
	}
	return len(d.cipher.EncryptFileName(name)) <= maxServerNameBytes
}

// shortForm is the name the server keeps for a full name: the name itself when it fits.
func (d *drive) shortForm(full string) string {
	if d.fitsServer(full) {
		return full
	}
	ext := path.Ext(full)
	if len(ext) > maxShortExtension || ext == full || strings.ContainsAny(ext, "~") {
		ext = ""
	}
	stem := strings.TrimSuffix(full, ext)
	suffix := "~" + nameHash(full) + ext
	// An encrypted name only grows with the plain one, so the longest start that fits is found by
	// going down from a length that can't, cutting only between characters.
	cut := min(len(stem), maxServerNameBytes)
	for cut > 0 {
		if cut == len(stem) || utf8.RuneStart(stem[cut]) {
			if candidate := stem[:cut] + suffix; d.fitsServer(candidate) {
				return candidate
			}
		}
		cut--
	}
	return suffix
}

// serverPath maps every name in a path to the one the server keeps.
func (d *drive) serverPath(p string) string {
	if d.cipher == nil || p == "" {
		return p
	}
	names := strings.Split(p, "/")
	for i, name := range names {
		names[i] = d.shortForm(name)
	}
	return strings.Join(names, "/")
}

// shownName is the full name kept in an item's details, if it's the one this short form stands
// for. Any other name, or one that doesn't hash back, says nothing.
func shownName(item json.RawMessage, leaf string) (string, bool) {
	match := shortFormHash.FindStringSubmatch(leaf)
	if match == nil || len(item) == 0 {
		return "", false
	}
	var fields struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(item, &fields); err != nil || fields.Name == "" || strings.Contains(fields.Name, "/") {
		return "", false
	}
	if nameHash(fields.Name) != match[1] {
		return "", false
	}
	return fields.Name, true
}

// itemNamed adds a full name to an item's details, keeping every other field word for word.
func itemNamed(item json.RawMessage, name string) json.RawMessage {
	fields := map[string]json.RawMessage{}
	if len(item) > 0 {
		if err := json.Unmarshal(item, &fields); err != nil {
			fields = map[string]json.RawMessage{}
		}
	}
	encoded, err := json.Marshal(name)
	if err != nil {
		return item
	}
	fields["name"] = encoded
	merged, err := json.Marshal(fields)
	if err != nil {
		return item
	}
	return merged
}

// fullNameKey carries a request's full leaf name down to where its details are written.
type fullNameKey struct{}

// withFullName remembers a request's full leaf name, when the server keeps it shortened.
func withFullName(ctx context.Context, full, short string) context.Context {
	if full == short {
		return ctx
	}
	return context.WithValue(ctx, fullNameKey{}, full)
}

// fullNameFor is the request's full name, when this server path's leaf is its short form. A
// conflict copy, or anything else written on the way, has another leaf and gets none.
func (d *drive) fullNameFor(ctx context.Context, serverPath string) (string, bool) {
	full, ok := ctx.Value(fullNameKey{}).(string)
	if !ok || d.shortForm(full) != path.Base(serverPath) {
		return "", false
	}
	return full, true
}

// shownPath puts a request's own folder names back in front of a path the server gave for it,
// so a folder with a long name is never returned under its short form.
func shownPath(p, serverDir, fullDir string) string {
	if serverDir == fullDir || serverDir == "" {
		return p
	}
	if p == serverDir {
		return fullDir
	}
	if strings.HasPrefix(p, serverDir+"/") {
		return fullDir + p[len(serverDir):]
	}
	return p
}
