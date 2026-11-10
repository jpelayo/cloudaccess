// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/webdav"
)

// propsFS is a WebDAV server's folder that keeps properties as Apache does: apart from the file,
// moving with renames, going with deletes, and staying behind when something writes over the file.
type propsFS struct {
	webdav.Dir
	mu    sync.Mutex
	props map[string]map[xml.Name]webdav.Property
}

func propsKey(name string) string {
	return path.Clean("/" + name)
}

func (f *propsFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	file, err := f.Dir.OpenFile(ctx, name, flag, perm)
	if err != nil && flag&os.O_RDWR != 0 {
		// Go's server opens a folder for writing to set a property on it, which a folder can't
		// be. Apache keeps a folder's properties, so this does too.
		if info, statErr := f.Dir.Stat(ctx, name); statErr == nil && info.IsDir() {
			file, err = f.Dir.OpenFile(ctx, name, os.O_RDONLY, 0)
		}
	}
	if err != nil {
		return nil, err
	}
	return &propsFile{File: file, fs: f, name: propsKey(name)}, nil
}

func (f *propsFS) RemoveAll(ctx context.Context, name string) error {
	err := f.Dir.RemoveAll(ctx, name)
	if err == nil {
		f.mu.Lock()
		defer f.mu.Unlock()
		key := propsKey(name)
		for held := range f.props {
			if held == key || strings.HasPrefix(held, key+"/") {
				delete(f.props, held)
			}
		}
	}
	return err
}

func (f *propsFS) Rename(ctx context.Context, oldName, newName string) error {
	err := f.Dir.Rename(ctx, oldName, newName)
	if err == nil {
		f.mu.Lock()
		defer f.mu.Unlock()
		from, to := propsKey(oldName), propsKey(newName)
		for held, props := range f.props {
			if held == from || strings.HasPrefix(held, from+"/") {
				delete(f.props, held)
				f.props[to+strings.TrimPrefix(held, from)] = props
			}
		}
	}
	return err
}

type propsFile struct {
	webdav.File
	fs   *propsFS
	name string
}

func (p *propsFile) DeadProps() (map[xml.Name]webdav.Property, error) {
	p.fs.mu.Lock()
	defer p.fs.mu.Unlock()
	copied := map[xml.Name]webdav.Property{}
	for name, prop := range p.fs.props[p.name] {
		copied[name] = prop
	}
	return copied, nil
}

func (p *propsFile) Patch(patches []webdav.Proppatch) ([]webdav.Propstat, error) {
	p.fs.mu.Lock()
	defer p.fs.mu.Unlock()
	held := p.fs.props[p.name]
	if held == nil {
		held = map[xml.Name]webdav.Property{}
	}
	stat := webdav.Propstat{Status: http.StatusOK}
	for _, patch := range patches {
		for _, prop := range patch.Props {
			stat.Props = append(stat.Props, webdav.Property{XMLName: prop.XMLName})
			if patch.Remove {
				delete(held, prop.XMLName)
			} else {
				held[prop.XMLName] = prop
			}
		}
	}
	p.fs.props[p.name] = held
	return []webdav.Propstat{stat}, nil
}

// methodCounter counts requests by method, to show what a save costs.
type methodCounter struct {
	mu     sync.Mutex
	counts map[string]int
	next   http.Handler
}

func (c *methodCounter) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	c.counts[r.Method]++
	c.mu.Unlock()
	c.next.ServeHTTP(w, r)
}

func (c *methodCounter) count(method string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.counts[method]
}

// startPropsWebDAV runs a WebDAV server that keeps properties like Apache.
func startPropsWebDAV(t *testing.T, folder string) (string, *methodCounter) {
	t.Helper()
	counter := &methodCounter{counts: map[string]int{}, next: &webdav.Handler{
		FileSystem: &propsFS{Dir: webdav.Dir(folder), props: map[string]map[xml.Name]webdav.Property{}},
		LockSystem: webdav.NewMemLS(),
	}}
	server := httptest.NewServer(counter)
	t.Cleanup(server.Close)
	return server.URL, counter
}

// detailsServer gives a fresh place on a server for one check: the local one that keeps
// properties like Apache, or the real server's test folder.
type detailsServer func(*testing.T) driveConfig

func localDetailsServer(t *testing.T) driveConfig {
	t.Helper()
	requireRclone(t)
	address, _ := startPropsWebDAV(t, t.TempDir())
	return driveConfig{Kind: "webdav", URL: address}
}

// openDetailsDrive opens one device's view of a drive on a server.
func openDetailsDrive(t *testing.T, config driveConfig, device string, encrypted bool) *drive {
	t.Helper()
	// Subtests put characters in their names that rclone refuses in a remote's name.
	config.ID = strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, driveID(t)+"-"+device)
	config.DeviceID, config.DeviceName, config.AppName = "device-"+device, device, "CloudAccess test"
	if encrypted {
		config.Encrypted, config.VaultPassword, config.CreateVault = true, interopPassword, true
	}
	if _, err := openDrive(context.Background(), config); err != nil {
		t.Fatalf("open drive: %v", err)
	}
	t.Cleanup(func() { closeDrive(config.ID) })
	d, err := lookupDrive(config.ID)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// saveWith saves a file as the Mac does, staging first and then committing with what it knows.
func saveWith(t *testing.T, d *drive, content []byte, p, base string, input fileInput) saveResult {
	t.Helper()
	ctx := context.Background()
	var counter atomic.Int64
	source := writeLocal(t, content)
	staged, err := d.stage(ctx, source, &counter)
	if err != nil {
		t.Fatalf("stage %s: %v", p, err)
	}
	result, err := d.commitStageWith(ctx, staged.Staged, source, p, base, false, &counter, input)
	if err != nil {
		t.Fatalf("commit %s: %v", p, err)
	}
	return result
}

func stat(t *testing.T, d *drive, p string) (remoteItem, rawEntry) {
	t.Helper()
	item, entry, err := d.serverStatEntry(context.Background(), p)
	if err != nil {
		t.Fatalf("stat %s: %v", p, err)
	}
	return item, entry
}

func sum(content []byte) string {
	digest := sha256.Sum256(content)
	return hex.EncodeToString(digest[:])
}

// plainPut writes over a file the way another tool would, with no claim and no details.
func plainPut(t *testing.T, config driveConfig, rawPath string, content []byte) {
	t.Helper()
	parts := strings.Split(rawPath, "/")
	for i, part := range parts {
		parts[i] = url.PathEscape(part)
	}
	request, err := http.NewRequest(http.MethodPut, strings.TrimSuffix(config.URL, "/")+"/"+strings.Join(parts, "/"), bytes.NewReader(content))
	if err != nil {
		t.Fatal(err)
	}
	if config.User != "" {
		request.SetBasicAuth(config.User, config.Password)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode >= 300 {
		t.Fatalf("plain PUT: status %d", response.StatusCode)
	}
}

var (
	ownModified = time.Date(2019, 3, 4, 10, 15, 30, 123456789, time.UTC)
	ownCreated  = time.Date(2018, 12, 1, 8, 0, 0, 0, time.UTC)
)

// The no-go gate: writing details must never change the file's bytes, size, date or ETag.
func checkDetailsNeverTouchTheFile(t *testing.T, server detailsServer) {
	for _, encrypted := range []bool{false, true} {
		t.Run(fmt.Sprintf("encrypted=%v", encrypted), func(t *testing.T) {
			d := openDetailsDrive(t, server(t), "a", encrypted)
			content := bytes.Repeat([]byte("the original bytes "), 5_000)
			result := saveWith(t, d, content, "report.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
			if result.DetailsMissed != "" {
				t.Fatalf("the save missed its details: %s", result.DetailsMissed)
			}
			before, beforeEntry := stat(t, d, "report.txt")
			if before.SHA256 != sum(content) {
				t.Fatalf("details recorded %q, want the original bytes' %q", before.SHA256, sum(content))
			}
			// Details written again, as a later device would, must leave the file exactly as it was.
			keeper := d.server.(detailsKeeper)
			if err := keeper.setDetails(context.Background(), d.rawFile("report.txt"), false, beforeEntry.Details); err != nil {
				t.Fatal(err)
			}
			after, afterEntry := stat(t, d, "report.txt")
			if afterEntry.ETag != beforeEntry.ETag || afterEntry.Size != beforeEntry.Size || !afterEntry.Modified.Equal(beforeEntry.Modified) {
				t.Errorf("writing details changed the file: %+v became %+v", beforeEntry, afterEntry)
			}
			if after.Version != before.Version {
				t.Error("writing details changed the file's version")
			}
			if got := read(t, d, "report.txt"); sum([]byte(got)) != sum(content) {
				t.Error("the file read back differently after its details were written")
			}
			// The download is checked against the recorded checksum, and passes.
			var counter atomic.Int64
			if err := d.download(context.Background(), "report.txt", filepath.Join(t.TempDir(), "checked"), &counter, after.SHA256); err != nil {
				t.Errorf("a download with its own checksum failed: %v", err)
			}
		})
	}
}

func TestFileDetailsNeverTouchTheFile(t *testing.T) {
	checkDetailsNeverTouchTheFile(t, localDetailsServer)
}

// A plain drive's file on disk is exactly the bytes sent, before and after details.
func TestAPlainFileOnDiskIsExactlyWhatWasSent(t *testing.T) {
	requireRclone(t)
	folder := t.TempDir()
	address, _ := startPropsWebDAV(t, folder)
	d := openDetailsDrive(t, driveConfig{Kind: "webdav", URL: address}, "a", false)
	content := []byte("exactly these bytes")
	saveWith(t, d, content, "exact.txt", "", fileInput{Modified: ownModified})
	stored, err := os.ReadFile(filepath.Join(folder, "exact.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, content) {
		t.Errorf("the server holds %q, want %q", stored, content)
	}
}

func checkDetailsCarryTheFilesOwnDates(t *testing.T, server detailsServer) {
	for _, encrypted := range []bool{false, true} {
		t.Run(fmt.Sprintf("encrypted=%v", encrypted), func(t *testing.T) {
			d := openDetailsDrive(t, server(t), "a", encrypted)
			saved := saveWith(t, d, []byte("dated"), "dated.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
			if saved.Item.OwnModifiedNS != ownModified.UnixNano() || saved.Item.CreatedNS != ownCreated.UnixNano() {
				t.Errorf("the save's reply carried %d and %d", saved.Item.OwnModifiedNS, saved.Item.CreatedNS)
			}
			listed, err := d.list(context.Background(), "")
			if err != nil {
				t.Fatal(err)
			}
			for _, item := range listed {
				if item.Path != "dated.txt" {
					continue
				}
				if item.OwnModifiedNS != ownModified.UnixNano() {
					t.Errorf("listed modified %v, want %v", time.Unix(0, item.OwnModifiedNS).UTC(), ownModified)
				}
				if item.CreatedNS != ownCreated.UnixNano() {
					t.Errorf("listed created %v, want %v", time.Unix(0, item.CreatedNS).UTC(), ownCreated)
				}
				// The server's own date stays, because versions depend on it.
				if item.ModifiedNS == 0 || item.ModifiedNS == ownModified.UnixNano() {
					t.Errorf("the server's own date was replaced: %d", item.ModifiedNS)
				}
				return
			}
			t.Fatal("the file wasn't listed")
		})
	}
}

func TestDetailsCarryTheFilesOwnDates(t *testing.T) {
	checkDetailsCarryTheFilesOwnDates(t, localDetailsServer)
}

// Fields a newer build wrote in item survive a save by this one, word for word, and a recorded
// creation date wins over what this Mac reports.
func checkUnknownFieldsAreCarriedForward(t *testing.T, server detailsServer) {
	d := openDetailsDrive(t, server(t), "a", false)
	first := saveWith(t, d, []byte("one"), "kept.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
	_, entry := stat(t, d, "kept.txt")
	var value map[string]any
	if err := json.Unmarshal([]byte(entry.Details), &value); err != nil {
		t.Fatal(err)
	}
	value["item"] = map[string]any{"created": ownCreated.Format(time.RFC3339Nano), "tags": []string{"red"}}
	value["future"] = "a top-level field from a newer build"
	changed, _ := json.Marshal(value)
	if err := d.server.(detailsKeeper).setDetails(context.Background(), d.rawFile("kept.txt"), false, string(changed)); err != nil {
		t.Fatal(err)
	}
	later := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	saveWith(t, d, []byte("two"), "kept.txt", first.Item.Version, fileInput{Modified: later, Created: later})
	item, entry := stat(t, d, "kept.txt")
	var after struct {
		Item map[string]json.RawMessage `json:"item"`
	}
	if err := json.Unmarshal([]byte(entry.Details), &after); err != nil {
		t.Fatal(err)
	}
	if string(after.Item["tags"]) != `["red"]` {
		t.Errorf("a newer build's item field became %s", after.Item["tags"])
	}
	if item.CreatedNS != ownCreated.UnixNano() {
		t.Errorf("the recorded creation date became %v", time.Unix(0, item.CreatedNS).UTC())
	}
	if item.OwnModifiedNS != later.UnixNano() {
		t.Error("the new content's date wasn't recorded")
	}
}

func TestUnknownFieldsAreReadAndCarriedForward(t *testing.T) {
	checkUnknownFieldsAreCarriedForward(t, localDetailsServer)
}

func checkDetailsTravelWithRenameTrashAndRestore(t *testing.T, server detailsServer) {
	d := openDetailsDrive(t, server(t), "a", true)
	ctx := context.Background()
	saved := saveWith(t, d, []byte("travelling"), "first.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
	moved, err := d.moveItem(ctx, "first.txt", "renamed.txt", saved.Item.Version)
	if err != nil {
		t.Fatal(err)
	}
	if moved.OwnModifiedNS != ownModified.UnixNano() || moved.CreatedNS != ownCreated.UnixNano() {
		t.Errorf("a rename lost the details: %+v", moved)
	}
	if err := d.trash(ctx, "renamed.txt", moved.Version); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(ctx)
	if err != nil || len(entries) != 1 {
		t.Fatalf("trash: %v, %v", entries, err)
	}
	if _, err := d.restoreFromTrash(ctx, entries[0].ID); err != nil {
		t.Fatal(err)
	}
	restored, _ := stat(t, d, "renamed.txt")
	if restored.OwnModifiedNS != ownModified.UnixNano() || restored.CreatedNS != ownCreated.UnixNano() {
		t.Errorf("a restore lost the details: %+v", restored)
	}
}

func TestDetailsTravelWithRenameTrashAndRestore(t *testing.T) {
	checkDetailsTravelWithRenameTrashAndRestore(t, localDetailsServer)
}

// Another tool writing over the file leaves the old property behind. The content details no
// longer describe the file, so they're ignored; what's about the item still holds.
func checkDetailsAnotherToolLeftBehindAreIgnored(t *testing.T, server detailsServer) {
	config := server(t)
	d := openDetailsDrive(t, config, "a", false)
	saveWith(t, d, []byte("ours"), "shared.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
	time.Sleep(1100 * time.Millisecond)
	plainPut(t, config, d.rawFile("shared.txt"), []byte("another tool's bytes"))
	item, entry := stat(t, d, "shared.txt")
	if entry.Details == "" {
		t.Skip("this server dropped the property on a write over the file")
	}
	if item.OwnModifiedNS != 0 || item.SHA256 != "" {
		t.Errorf("stale details were believed: %+v", item)
	}
	if item.CreatedNS != ownCreated.UnixNano() {
		t.Errorf("the item's creation date went too: %+v", item)
	}
}

func TestDetailsAnotherToolLeftBehindAreIgnored(t *testing.T) {
	checkDetailsAnotherToolLeftBehindAreIgnored(t, localDetailsServer)
}

func checkEncryptedDetailsTellTheServerNothing(t *testing.T, server detailsServer) {
	d := openDetailsDrive(t, server(t), "a", true)
	content := []byte("secret content")
	saveWith(t, d, content, "secret.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
	item, entry := stat(t, d, "secret.txt")
	for _, leak := range []string{"2019-03-04", "2018-12-01", sum(content), "secret", `"size"`, "CloudAccess test"} {
		if strings.Contains(entry.Details, leak) {
			t.Errorf("the server can read %q in %s", leak, entry.Details)
		}
	}
	if !strings.Contains(entry.Details, `"sealed"`) || item.OwnModifiedNS != ownModified.UnixNano() {
		t.Fatalf("details weren't sealed and read back: %s", entry.Details)
	}
	if len(entry.Details) > maxDetailsBytes {
		t.Errorf("%d bytes is more than stock Apache keeps", len(entry.Details))
	}
	// A seal the server tampered with doesn't open, so it says nothing.
	var outer map[string]any
	_ = json.Unmarshal([]byte(entry.Details), &outer)
	sealed := []byte(outer["sealed"].(string))
	sealed[len(sealed)/2] ^= 1
	outer["sealed"] = string(sealed)
	tampered, _ := json.Marshal(outer)
	if err := d.server.(detailsKeeper).setDetails(context.Background(), d.rawFile("secret.txt"), false, string(tampered)); err != nil {
		t.Fatal(err)
	}
	if tamperedItem, _ := stat(t, d, "secret.txt"); tamperedItem.OwnModifiedNS != 0 || tamperedItem.CreatedNS != 0 {
		t.Error("a tampered seal was believed")
	}
}

func TestEncryptedDetailsTellTheServerNothing(t *testing.T) {
	checkEncryptedDetailsTellTheServerNothing(t, localDetailsServer)
}

// Details copied from another encrypted drive, by another tool, aren't this drive's.
func TestDetailsFromAnotherDriveAreIgnored(t *testing.T) {
	ours := openDetailsDrive(t, localDetailsServer(t), "a", true)
	theirs := openDetailsDrive(t, localDetailsServer(t), "b", true)
	saveWith(t, ours, []byte("ours"), "file.txt", "", fileInput{Modified: ownModified})
	saveWith(t, theirs, []byte("theirs"), "file.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
	_, theirEntry := stat(t, theirs, "file.txt")
	if err := ours.server.(detailsKeeper).setDetails(context.Background(), ours.rawFile("file.txt"), false, theirEntry.Details); err != nil {
		t.Fatal(err)
	}
	if item, _ := stat(t, ours, "file.txt"); item.CreatedNS != 0 || item.OwnModifiedNS != 0 {
		t.Errorf("another drive's details were believed: %+v", item)
	}
}

// A server that won't keep properties fails the check once, and saves carry on as they always did.
func TestAServerThatRefusesDetailsStillSaves(t *testing.T) {
	requireRclone(t)
	folder := t.TempDir()
	counter := &methodCounter{counts: map[string]int{}, next: &webdav.Handler{
		FileSystem: webdav.Dir(folder), LockSystem: webdav.NewMemLS(),
	}}
	server := httptest.NewServer(counter)
	t.Cleanup(server.Close)
	d := openDetailsDrive(t, driveConfig{Kind: "webdav", URL: server.URL}, "a", false)
	first := saveWith(t, d, []byte("one"), "plain.txt", "", fileInput{Modified: ownModified})
	if first.Item.OwnModifiedNS != 0 || first.DetailsMissed != "" {
		t.Errorf("a server that refuses details got some: %+v", first)
	}
	checked := counter.count("PROPPATCH")
	saveWith(t, d, []byte("two"), "plain.txt", first.Item.Version, fileInput{Modified: ownModified})
	if counter.count("PROPPATCH") != checked {
		t.Error("a server known to refuse details was asked again")
	}
	if got := read(t, d, "plain.txt"); got != "two" {
		t.Errorf("the save didn't land: %q", got)
	}
	// Another device takes the recorded answer instead of checking again.
	other := openDetailsDrive(t, driveConfig{Kind: "webdav", URL: server.URL}, "b", false)
	saveWith(t, other, []byte("three"), "other.txt", "", fileInput{})
	if counter.count("PROPPATCH") != checked {
		t.Error("another device checked the server again")
	}
}

// After the first save has checked the server, a save writes its details with one request.
func TestASaveWritesItsDetailsWithOneRequest(t *testing.T) {
	requireRclone(t)
	address, counter := startPropsWebDAV(t, t.TempDir())
	d := openDetailsDrive(t, driveConfig{Kind: "webdav", URL: address}, "a", false)
	first := saveWith(t, d, []byte("one"), "counted.txt", "", fileInput{Modified: ownModified})
	patches, gets := counter.count("PROPPATCH"), counter.count("GET")
	saveWith(t, d, []byte("two"), "counted.txt", first.Item.Version, fileInput{Modified: ownModified})
	if added := counter.count("PROPPATCH") - patches; added != 1 {
		t.Errorf("a save sent %d PROPPATCH requests, want 1", added)
	}
	if counter.count("GET") != gets {
		t.Error("a save read the server's answer again")
	}
}

func TestADownloadThatDoesntMatchItsChecksumFails(t *testing.T) {
	d := openDetailsDrive(t, localDetailsServer(t), "a", false)
	saveWith(t, d, []byte("checked bytes"), "checked.txt", "", fileInput{})
	var counter atomic.Int64
	destination := filepath.Join(t.TempDir(), "out")
	err := d.download(context.Background(), "checked.txt", destination, &counter, sum([]byte("other bytes")))
	if !errors.Is(err, errFileDamaged) {
		t.Fatalf("a download that didn't match came back as %v", err)
	}
	if _, err := os.Stat(destination); !os.IsNotExist(err) {
		t.Error("damaged bytes reached the destination")
	}
}

func TestDamagedDetailsAreIgnored(t *testing.T) {
	d := openDetailsDrive(t, localDetailsServer(t), "a", false)
	saveWith(t, d, []byte("content"), "file.txt", "", fileInput{Modified: ownModified, Created: ownCreated})
	_, good := stat(t, d, "file.txt")
	var template map[string]any
	_ = json.Unmarshal([]byte(good.Details), &template)
	variant := func(change func(map[string]any)) string {
		copied := map[string]any{}
		encoded, _ := json.Marshal(template)
		_ = json.Unmarshal(encoded, &copied)
		change(copied)
		result, _ := json.Marshal(copied)
		return string(result)
	}
	for name, value := range map[string]string{
		"not JSON":      "{not json",
		"too big":       `{"format":1,"pad":"` + strings.Repeat("x", maxDetailsReadBytes) + `"}`,
		"higher format": variant(func(m map[string]any) { m["format"] = 2 }),
		"a folder's":    variant(func(m map[string]any) { m["kind"] = "folder" }),
		"unknown kind":  variant(func(m map[string]any) { m["kind"] = "symlink" }),
		"encrypted":     variant(func(m map[string]any) { m["encryption"] = map[string]any{"type": "rclone-crypt"} }),
		"future date":   variant(func(m map[string]any) { m["item"] = map[string]any{"created": "2999-01-01T00:00:00Z"} }),
		"bad created":   variant(func(m map[string]any) { m["item"] = map[string]any{"created": "yesterday"} }),
		"another etag": variant(func(m map[string]any) {
			m["content"].(map[string]any)["describes"].(map[string]any)["etag"] = `"other"`
		}),
		"another size":   variant(func(m map[string]any) { m["content"].(map[string]any)["size"] = 1 }),
		"bad checksum":   variant(func(m map[string]any) { m["content"].(map[string]any)["sha256"] = "ABC" }),
		"not an object":  `[1,2,3]`,
		"empty object":   `{}`,
		"null item":      variant(func(m map[string]any) { m["item"] = nil }),
		"number created": variant(func(m map[string]any) { m["item"] = map[string]any{"created": 12} }),
	} {
		t.Run(name, func(t *testing.T) {
			if err := d.server.(detailsKeeper).setDetails(context.Background(), d.rawFile("file.txt"), false, value); err != nil {
				t.Fatal(err)
			}
			item, err := d.stat(context.Background(), "file.txt")
			if err != nil {
				t.Fatalf("a damaged property made the file unreadable: %v", err)
			}
			switch name {
			case "another etag", "another size", "bad checksum":
				if item.SHA256 != "" && name != "bad checksum" {
					t.Errorf("stale content was believed: %+v", item)
				}
				if name == "bad checksum" && item.SHA256 != "" {
					t.Error("a malformed checksum was believed")
				}
			case "future date", "bad created", "null item", "number created":
				if item.CreatedNS != 0 {
					t.Errorf("an impossible creation date was believed: %+v", item)
				}
			default:
				if item.OwnModifiedNS != 0 || item.CreatedNS != 0 || item.SHA256 != "" {
					t.Errorf("damaged details were believed: %+v", item)
				}
			}
		})
	}
}

// A higher format isn't read, and isn't rewritten by anything but a save that replaces the file.
func TestAHigherFormatIsLeftAlone(t *testing.T) {
	d := openDetailsDrive(t, localDetailsServer(t), "a", false)
	ctx := context.Background()
	saved := saveWith(t, d, []byte("content"), "future.txt", "", fileInput{Modified: ownModified})
	newer := `{"format":2,"kind":"file","meaning":"changed"}`
	if err := d.server.(detailsKeeper).setDetails(ctx, d.rawFile("future.txt"), false, newer); err != nil {
		t.Fatal(err)
	}
	if item, _ := stat(t, d, "future.txt"); item.OwnModifiedNS != 0 {
		t.Error("a higher format was read")
	}
	moved, err := d.moveItem(ctx, "future.txt", "moved.txt", saved.Item.Version)
	if err != nil {
		t.Fatal(err)
	}
	if _, entry := stat(t, d, "moved.txt"); entry.Details != newer {
		t.Errorf("a move rewrote a higher format: %s", entry.Details)
	}
	saveWith(t, d, []byte("replaced"), "moved.txt", moved.Version, fileInput{Modified: ownModified})
	if item, _ := stat(t, d, "moved.txt"); item.OwnModifiedNS != ownModified.UnixNano() {
		t.Error("a save that replaced the file didn't describe the new bytes")
	}
}

func checkABundleIsDescribedAsOne(t *testing.T, server detailsServer) {
	d := openDetailsDrive(t, server(t), "a", false)
	flattened := bytes.Repeat([]byte{0x50, 0x4b, 0x03, 0x04}, 1000)
	saved := saveWith(t, d, flattened, "Report.numbers.pkgf", "",
		fileInput{Modified: ownModified, Created: ownCreated, BundleType: "com.apple.iwork.numbers.numbers"})
	if saved.Item.Kind != "bundle" || saved.Item.BundleType != "com.apple.iwork.numbers.numbers" {
		t.Errorf("a package was described as %q, %q", saved.Item.Kind, saved.Item.BundleType)
	}
	if saved.Item.SHA256 != sum(flattened) {
		t.Error("a package's checksum isn't its flattened bytes'")
	}
	_, entry := stat(t, d, "Report.numbers.pkgf")
	if !strings.Contains(entry.Details, `"storedAs":"apple-flattened-package"`) {
		t.Errorf("how the package is stored wasn't recorded: %s", entry.Details)
	}
}

func TestABundleIsDescribedAsOne(t *testing.T) {
	checkABundleIsDescribedAsOne(t, localDetailsServer)
}

func checkAFolderKeepsItsCreationDate(t *testing.T, server detailsServer) {
	config := server(t)
	a := openDetailsDrive(t, config, "a", false)
	b := openDetailsDrive(t, config, "b", false)
	ctx := context.Background()
	// The first save checks the server, so a folder made afterwards can be described.
	saveWith(t, a, []byte("x"), "warm.txt", "", fileInput{})
	saveWith(t, b, []byte("y"), "warm2.txt", "", fileInput{})
	if err := a.mkdirWith(ctx, "Projects", ownCreated); err != nil {
		t.Fatal(err)
	}
	later := ownCreated.Add(48 * time.Hour)
	if err := b.mkdirWith(ctx, "Projects", later); err != nil {
		t.Fatalf("a folder another device made first is still made: %v", err)
	}
	listed, err := b.list(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range listed {
		if item.Path == "Projects" {
			if item.CreatedNS != ownCreated.UnixNano() {
				t.Errorf("the folder says it was created %v", time.Unix(0, item.CreatedNS).UTC())
			}
			return
		}
	}
	t.Fatal("the folder wasn't listed")
}

func TestAFolderKeepsItsCreationDate(t *testing.T) {
	checkAFolderKeepsItsCreationDate(t, localDetailsServer)
}

func checkAConflictCopyKeepsItsDates(t *testing.T, server detailsServer) {
	config := server(t)
	a := openDetailsDrive(t, config, "a", true)
	b := openDetailsDrive(t, config, "b", true)
	base := saveWith(t, a, []byte("base"), "shared.txt", "", fileInput{})
	saveWith(t, a, []byte("a's edit"), "shared.txt", base.Item.Version, fileInput{})
	result := saveWith(t, b, []byte("b's edit"), "shared.txt", base.Item.Version, fileInput{Modified: ownModified, Created: ownCreated})
	if result.ConflictPath == "" {
		t.Fatal("no conflict copy was made")
	}
	copied, _ := stat(t, b, result.ConflictPath)
	if copied.OwnModifiedNS != ownModified.UnixNano() || copied.CreatedNS != ownCreated.UnixNano() {
		t.Errorf("the conflict copy lost its dates: %+v", copied)
	}
}

func TestAConflictCopyKeepsItsDates(t *testing.T) {
	checkAConflictCopyKeepsItsDates(t, localDetailsServer)
}

// Details stay small enough for stock Apache, even for an encrypted package with a long type.
func TestDetailsFitStockApache(t *testing.T) {
	d := openDetailsDrive(t, localDetailsServer(t), "a", true)
	result := saveWith(t, d, []byte("pkg"), "A rather long document name.numbers.pkgf", "",
		fileInput{Modified: ownModified, Created: ownCreated, BundleType: strings.Repeat("t", maxBundleType)})
	_, entry := stat(t, d, "A rather long document name.numbers.pkgf")
	if result.DetailsMissed != "" || len(entry.Details) > maxDetailsBytes {
		t.Errorf("%d bytes, missed %q", len(entry.Details), result.DetailsMissed)
	}
	t.Logf("an encrypted package's details at their largest: %d bytes", len(entry.Details))
}

// What details cost a save on the real server. Saves with and without them alternate, so the
// network's mood on the day is the same for both.
func TestLiveDetailsCost(t *testing.T) {
	if os.Getenv("CM_LIVE_SERVER") != "webdav" {
		t.Skip("Tools/test-live-races.sh webdav runs this against the real server")
	}
	config := liveServer("webdav")(t, "")
	with := openDetailsDrive(t, config, "with", true)
	without := openDetailsDrive(t, config, "without", true)
	// Both warm up, so folders, the vault check and the server check are behind them.
	saveWith(t, with, []byte("warm"), "with/warm.txt", "", fileInput{Modified: ownModified})
	saveWith(t, without, []byte("warm"), "without/warm.txt", "", fileInput{Modified: ownModified})
	if !with.keepsDetails(context.Background()) {
		t.Fatal("the server didn't pass the check")
	}
	without.detailsMu.Lock()
	without.detailsKnown, without.detailsKept = true, false
	without.detailsMu.Unlock()

	const rounds = 15
	var newWith, newWithout, replaceWith, replaceWithout time.Duration
	versions := map[string]string{}
	timed := func(d *drive, p, base string) (time.Duration, string) {
		started := time.Now()
		result := saveWith(t, d, []byte(p+base), p, base, fileInput{Modified: ownModified, Created: ownCreated})
		return time.Since(started), result.Item.Version
	}
	for run := range rounds {
		name := fmt.Sprintf("file-%d.txt", run)
		var spent time.Duration
		spent, versions["with/"+name] = timed(with, "with/"+name, "")
		newWith += spent
		spent, versions["without/"+name] = timed(without, "without/"+name, "")
		newWithout += spent
	}
	for run := range rounds {
		name := fmt.Sprintf("file-%d.txt", run)
		spent, _ := timed(with, "with/"+name, versions["with/"+name])
		replaceWith += spent
		spent, _ = timed(without, "without/"+name, versions["without/"+name])
		replaceWithout += spent
	}
	each := func(total time.Duration) time.Duration { return (total / rounds).Round(time.Millisecond) }
	t.Logf("a new file: %v with details, %v without", each(newWith), each(newWithout))
	t.Logf("replacing a file: %v with details, %v without", each(replaceWith), each(replaceWithout))
}

// Every check against the real server, in the test folder only.
func TestLiveFileDetails(t *testing.T) {
	if os.Getenv("CM_LIVE_SERVER") != "webdav" {
		t.Skip("Tools/test-live-races.sh webdav runs this against the real server")
	}
	live := detailsServer(func(t *testing.T) driveConfig {
		t.Helper()
		return liveServer("webdav")(t, "")
	})
	for _, check := range []struct {
		name string
		run  func(*testing.T, detailsServer)
	}{
		{"NeverTouchTheFile", checkDetailsNeverTouchTheFile},
		{"CarryTheFilesOwnDates", checkDetailsCarryTheFilesOwnDates},
		{"UnknownFieldsAreCarriedForward", checkUnknownFieldsAreCarriedForward},
		{"TravelWithRenameTrashAndRestore", checkDetailsTravelWithRenameTrashAndRestore},
		{"AnotherToolLeftBehindAreIgnored", checkDetailsAnotherToolLeftBehindAreIgnored},
		{"EncryptedTellTheServerNothing", checkEncryptedDetailsTellTheServerNothing},
		{"ABundleIsDescribedAsOne", checkABundleIsDescribedAsOne},
		{"AFolderKeepsItsCreationDate", checkAFolderKeepsItsCreationDate},
		{"AConflictCopyKeepsItsDates", checkAConflictCopyKeepsItsDates},
	} {
		t.Run(check.name, func(t *testing.T) { check.run(t, live) })
	}
}
