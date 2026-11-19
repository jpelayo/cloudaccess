// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"
)

// call runs a method the way Swift does, through dispatch.
func call(t *testing.T, method string, arguments map[string]any) (any, error) {
	t.Helper()
	encoded, err := json.Marshal(arguments)
	if err != nil {
		t.Fatal(err)
	}
	var counter atomic.Int64
	return dispatch(context.Background(), method, encoded, &counter)
}

func longNames() []string {
	return []string{
		strings.Repeat("a", 200) + ".pdf",
		strings.Repeat("é", 120) + ".txt",
		strings.Repeat("Informe anual de la comisión ", 8) + "final.docx",
		strings.Repeat("x", 255),
		strings.Repeat("y", 180) + "." + strings.Repeat("z", 40),
	}
}

func TestAShortFormFitsAnEncryptedDrive(t *testing.T) {
	d, _ := newDrive(t, true)
	for _, full := range longNames() {
		short := d.shortForm(full)
		if short == full {
			t.Fatalf("%d bytes weren't shortened", len(full))
		}
		if raw := d.cipher.EncryptFileName(short); len(raw) > maxServerNameBytes {
			t.Errorf("short form is %d bytes on the server", len(raw))
		}
		if !utf8.ValidString(short) {
			t.Errorf("short form %q cuts a character", short)
		}
		if d.shortForm(full) != short {
			t.Error("the short form isn't the same every time")
		}
		if !strings.HasPrefix(full, strings.SplitN(short, "~", 2)[0]) {
			t.Errorf("short form %q doesn't start like %q", short, full)
		}
	}
}

func TestAShortFormKeepsTheExtension(t *testing.T) {
	d, _ := newDrive(t, true)
	if short := d.shortForm(strings.Repeat("a", 200) + ".pdf"); !strings.HasSuffix(short, ".pdf") {
		t.Errorf("%q lost its extension", short)
	}
	// An extension too long to keep isn't kept, and the name still fits.
	if short := d.shortForm(strings.Repeat("y", 180) + "." + strings.Repeat("z", 40)); strings.Contains(short, "."+strings.Repeat("z", 40)) {
		t.Errorf("%q kept a 41-byte extension", short)
	}
}

func TestTwoLongNamesSharingAStartGetDifferentShortForms(t *testing.T) {
	d, _ := newDrive(t, true)
	start := strings.Repeat("a", 200)
	if d.shortForm(start+"1.txt") == d.shortForm(start+"2.txt") {
		t.Error("two names got one short form")
	}
}

// Backwards compatibility: every name that fits is kept exactly as before, so every file already
// on a server is reached as it always was.
func TestANameThatFitsIsNeverChanged(t *testing.T) {
	d, _ := newDrive(t, true)
	for _, name := range []string{"Notes.txt", strings.Repeat("a", 100) + ".pdf", "report~abcdefghij.pdf", "Ñandú.md"} {
		if d.shortForm(name) != name {
			t.Errorf("%q was changed", name)
		}
	}
	if p := "a/b/" + strings.Repeat("c", 90); d.serverPath(p) != p {
		t.Errorf("%q was changed", p)
	}
}

// A plain drive's names are its files' own, whatever their length: nothing is ever shortened.
func TestAPlainDriveNeverShortens(t *testing.T) {
	d, _ := newDrive(t, false)
	for _, full := range longNames() {
		if d.shortForm(full) != full || d.serverPath("dir/"+full) != "dir/"+full {
			t.Errorf("a plain drive shortened %d bytes", len(full))
		}
	}
}

func TestANameThatDoesntHashBackIsIgnored(t *testing.T) {
	d, _ := newDrive(t, true)
	full := strings.Repeat("a", 200) + ".pdf"
	short := d.shortForm(full)
	if name, ok := shownName(itemNamed(nil, full), short); !ok || name != full {
		t.Fatalf("the right name wasn't shown: %q %v", name, ok)
	}
	if _, ok := shownName(itemNamed(nil, "Something else.pdf"), short); ok {
		t.Error("a name that doesn't hash back was shown")
	}
	// A person's own file named like a short form has no name in its details, and stays as it is.
	if _, ok := shownName(nil, "report~abcdefghij.pdf"); ok {
		t.Error("a name with no details was changed")
	}
}

func TestItemNamedKeepsEveryOtherField(t *testing.T) {
	named := itemNamed(json.RawMessage(`{"created":"2026-01-02T03:04:05Z","future":{"x":1}}`), "Long.pdf")
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(named, &fields); err != nil {
		t.Fatal(err)
	}
	if string(fields["future"]) != `{"x":1}` || string(fields["created"]) != `"2026-01-02T03:04:05Z"` {
		t.Errorf("fields weren't kept: %s", named)
	}
}

// Without details, as on SFTP or this local stand-in, a long name lands under its short form,
// and its folder's own long name is still the one returned.
func TestALongNameSavesWithoutDetailsUnderItsShortForm(t *testing.T) {
	d, _ := newDrive(t, true)
	id := driveID(t)
	folder := strings.Repeat("Carpeta con un nombre muy largo ", 6)
	file := strings.Repeat("Documento con un nombre larguísimo ", 6) + ".txt"
	if _, err := call(t, "mkdir", map[string]any{"drive": id, "path": folder}); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	source := writeLocal(t, []byte("hello"))
	if _, err := call(t, "save", map[string]any{"drive": id, "path": folder + "/" + file, "source": source}); err != nil {
		t.Fatalf("save: %v", err)
	}
	listed, err := call(t, "list", map[string]any{"drive": id, "path": folder})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	items := listed.([]remoteItem)
	if len(items) != 1 {
		t.Fatalf("listed %d items", len(items))
	}
	if want := folder + "/" + d.shortForm(file); items[0].Path != want {
		t.Errorf("listed %q, want %q", items[0].Path, want)
	}
	// It reads back by either name a person could hold.
	destination := path.Join(t.TempDir(), "out")
	if _, err := call(t, "download", map[string]any{"drive": id, "path": items[0].Path, "destination": destination}); err != nil {
		t.Fatalf("download: %v", err)
	}
	if got, _ := os.ReadFile(destination); string(got) != "hello" {
		t.Errorf("read back %q", got)
	}
}

// With details, the full name is kept and shown, through a save, a rename and a new folder.
func TestALongNameRoundTripsInTheDetails(t *testing.T) {
	config := localDetailsServer(t)
	d := openDetailsDrive(t, config, "mac", true)
	id := openID(t, d)
	folder := strings.Repeat("Proyectos del año con nombre largo ", 6)
	first := strings.Repeat("Acta de la reunión extraordinaria ", 6) + ".pdf"
	second := strings.Repeat("Acta renombrada con otro nombre ", 6) + ".pdf"
	if _, err := call(t, "mkdir", map[string]any{"drive": id, "path": folder, "createdNs": time.Now().UnixNano()}); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	root, err := call(t, "list", map[string]any{"drive": id, "path": ""})
	if err != nil {
		t.Fatalf("list top: %v", err)
	}
	if items := root.([]remoteItem); len(items) != 1 || items[0].Path != folder {
		t.Fatalf("the folder's full name wasn't shown: %+v", items)
	}
	source := writeLocal(t, []byte("minutes"))
	saved, err := call(t, "save", map[string]any{"drive": id, "path": folder + "/" + first, "source": source})
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if got := saved.(saveResult).Item.Path; got != folder+"/"+first {
		t.Errorf("save returned %q", got)
	}
	moved, err := call(t, "move", map[string]any{
		"drive": id, "source": folder + "/" + first, "destination": folder + "/" + second,
		"baseVersion": saved.(saveResult).Item.Version,
	})
	if err != nil {
		t.Fatalf("move: %v", err)
	}
	if got := moved.(remoteItem).Path; got != folder+"/"+second {
		t.Errorf("move returned %q", got)
	}
	listed, err := call(t, "list", map[string]any{"drive": id, "path": folder})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if items := listed.([]remoteItem); len(items) != 1 || items[0].Path != folder+"/"+second {
		t.Errorf("listed %+v", items)
	}
}

// The full name has to fit the 900 bytes a stock Apache keeps. If the longest one ever doesn't,
// it's left out and the file keeps its short form, its dates and its check.
func TestTheWorstCaseNameFitsOrIsLeftOut(t *testing.T) {
	d, _ := newDrive(t, true)
	content := &detailsContent{
		Modified: time.Now().UTC().Format(time.RFC3339Nano), Size: 1 << 40,
		SHA256: strings.Repeat("a", 64), Bundle: &detailsBundle{StoredAs: bundleStoredAs, Type: strings.Repeat("t", maxBundleType)},
		Describes: detailsVersion{ETag: strings.Repeat("e", 64), StoredSize: 1 << 40},
	}
	worst := strings.Repeat("é", 127) + "a"
	item := itemNamed(mergeItem(nil, time.Now()), worst)
	value, err := d.encodeDetails("bundle", content, item, maxDetailsBytes)
	switch {
	case err == nil:
		t.Logf("the worst case takes %d of %d bytes", len(value), maxDetailsBytes)
	case errors.Is(err, errDetailsTooBig):
		t.Logf("the worst case doesn't fit, so its name is left out")
		if _, err := d.encodeDetails("bundle", content, mergeItem(nil, time.Now()), maxDetailsBytes); err != nil {
			t.Errorf("without the name it still doesn't fit: %v", err)
		}
	default:
		t.Fatal(err)
	}
}

// openID is the ID a drive was opened under.
func openID(t *testing.T, d *drive) string {
	t.Helper()
	drivesMu.RLock()
	defer drivesMu.RUnlock()
	for id, open := range drives {
		if open == d {
			return id
		}
	}
	t.Fatal("the drive isn't open")
	return ""
}
