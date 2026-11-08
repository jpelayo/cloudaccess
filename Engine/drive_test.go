// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/rclone/rclone/fs"
)

const secretName = "Contrato Secreto.txt"

var secretContent = []byte(strings.Repeat("confidential text ", 20000))

func TestMain(m *testing.M) {
	configureRclone()
	os.Exit(m.Run())
}

func driveID(t *testing.T) string {
	return strings.NewReplacer("/", "-", "#", "-").Replace(t.Name())
}

// newDrive opens a drive over a temporary folder that stands in for the server.
func newDrive(t *testing.T, encrypted bool) (d *drive, serverDir string) {
	t.Helper()
	serverDir = t.TempDir()
	id := driveID(t)
	_, err := openDrive(context.Background(), driveConfig{
		ID: id, Kind: "local", RootPath: serverDir,
		Encrypted: encrypted, VaultPassword: "correct horse", CreateVault: true,
	})
	if err != nil {
		t.Fatalf("open drive: %v", err)
	}
	t.Cleanup(func() { closeDrive(id) })
	d, err = lookupDrive(id)
	if err != nil {
		t.Fatal(err)
	}
	return d, serverDir
}

func writeLocal(t *testing.T, content []byte) string {
	t.Helper()
	file := filepath.Join(t.TempDir(), "source")
	if err := os.WriteFile(file, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return file
}

// serverFiles lists user data on the server, leaving out the control folder.
func serverFiles(t *testing.T, root string) []string {
	t.Helper()
	var files []string
	err := filepath.WalkDir(root, func(p string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() && entry.Name() == controlFolder {
			return filepath.SkipDir
		}
		if !entry.IsDir() {
			files = append(files, p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}

func TestEncryptedRoundTripHidesNameAndContent(t *testing.T) {
	ctx := context.Background()
	d, server := newDrive(t, true)
	var counter atomic.Int64

	uploaded, err := d.upload(ctx, writeLocal(t, secretContent), "Clientes/"+secretName, &counter)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	if uploaded.Size != int64(len(secretContent)) {
		t.Errorf("reported size %d, want the plain size %d", uploaded.Size, len(secretContent))
	}
	if counter.Load() != int64(len(secretContent)) {
		t.Errorf("progress %d, want %d", counter.Load(), len(secretContent))
	}

	files := serverFiles(t, server)
	if len(files) != 1 {
		t.Fatalf("server holds %d files, want 1", len(files))
	}
	if strings.Contains(files[0], "Clientes") || strings.Contains(files[0], "Secreto") {
		t.Errorf("a plain name reached the server: %s", files[0])
	}
	raw, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("confidential")) {
		t.Error("plain content reached the server")
	}
	if !bytes.HasPrefix(raw, []byte("RCLONE\x00\x00")) {
		t.Error("file does not use the rclone crypt format")
	}

	destination := filepath.Join(t.TempDir(), "out")
	if err := d.download(ctx, "Clientes/"+secretName, destination, &counter, ""); err != nil {
		t.Fatalf("download: %v", err)
	}
	got, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, secretContent) {
		t.Error("downloaded content differs from what was uploaded")
	}
}

func TestListShowsPlainNamesAndSizes(t *testing.T) {
	ctx := context.Background()
	d, _ := newDrive(t, true)
	var counter atomic.Int64
	if _, err := d.upload(ctx, writeLocal(t, []byte("hello")), "docs/a.txt", &counter); err != nil {
		t.Fatal(err)
	}

	root, err := d.list(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(root) != 1 || root[0].Path != "docs" || !root[0].IsDirectory {
		t.Fatalf("root listing = %+v", root)
	}
	inside, err := d.list(ctx, "docs")
	if err != nil {
		t.Fatal(err)
	}
	if len(inside) != 1 || inside[0].Path != "docs/a.txt" || inside[0].Size != 5 {
		t.Fatalf("folder listing = %+v", inside)
	}
}

func TestRangedReadAcrossEncryptedChunks(t *testing.T) {
	ctx := context.Background()
	d, _ := newDrive(t, true)
	var counter atomic.Int64
	content := make([]byte, 200_000)
	for i := range content {
		content[i] = byte(i % 251)
	}
	if _, err := d.upload(ctx, writeLocal(t, content), "big.bin", &counter); err != nil {
		t.Fatal(err)
	}

	destination := filepath.Join(t.TempDir(), "part")
	const offset, length = 70_000, 80_000 // spans the 64 KiB chunk boundaries
	if err := d.readRange(ctx, "big.bin", offset, length, destination, &counter); err != nil {
		t.Fatalf("read: %v", err)
	}
	got, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, content[offset:offset+length]) {
		t.Errorf("read %d bytes that don't match the requested range", len(got))
	}
}

func TestStatFindsFilesFoldersAndMissingItems(t *testing.T) {
	ctx := context.Background()
	d, _ := newDrive(t, true)
	var counter atomic.Int64
	if _, err := d.upload(ctx, writeLocal(t, []byte("x")), "folder/file", &counter); err != nil {
		t.Fatal(err)
	}

	if item, err := d.stat(ctx, "folder/file"); err != nil || item.IsDirectory {
		t.Errorf("file: %+v, %v", item, err)
	}
	if item, err := d.stat(ctx, "folder"); err != nil || !item.IsDirectory {
		t.Errorf("folder: %+v, %v", item, err)
	}
	if item, err := d.stat(ctx, ""); err != nil || !item.IsDirectory {
		t.Errorf("root: %+v, %v", item, err)
	}
	_, err := d.stat(ctx, "folder/missing")
	if !errors.Is(err, fs.ErrorObjectNotFound) {
		t.Errorf("missing item: %v", err)
	}
}

func TestMkdirCreatesMissingParents(t *testing.T) {
	ctx := context.Background()
	d, _ := newDrive(t, true)
	if err := d.mkdir(ctx, "a/b/c"); err != nil {
		t.Fatal(err)
	}
	if item, err := d.stat(ctx, "a/b/c"); err != nil || !item.IsDirectory {
		t.Errorf("stat: %+v, %v", item, err)
	}
}

func TestMoveAndRenameKeepContent(t *testing.T) {
	ctx := context.Background()
	d, _ := newDrive(t, true)
	var counter atomic.Int64
	if _, err := d.upload(ctx, writeLocal(t, []byte("payload")), "one/file.txt", &counter); err != nil {
		t.Fatal(err)
	}

	if err := d.move(ctx, "one/file.txt", "two/renamed.txt"); err != nil {
		t.Fatalf("move file: %v", err)
	}
	if err := d.move(ctx, "two", "three"); err != nil {
		t.Fatalf("move folder: %v", err)
	}

	destination := filepath.Join(t.TempDir(), "out")
	if err := d.download(ctx, "three/renamed.txt", destination, &counter, ""); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(destination); string(got) != "payload" {
		t.Errorf("content after move = %q", got)
	}
}

// The plan relies on this to spot server-side renames while polling.
func TestCryptNonceSurvivesServerSideMove(t *testing.T) {
	ctx := context.Background()
	d, server := newDrive(t, true)
	var counter atomic.Int64
	if _, err := d.upload(ctx, writeLocal(t, []byte("payload")), "before.txt", &counter); err != nil {
		t.Fatal(err)
	}
	header := func() []byte {
		raw, err := os.ReadFile(serverFiles(t, server)[0])
		if err != nil {
			t.Fatal(err)
		}
		return raw[:32]
	}
	first := header()
	if err := d.move(ctx, "before.txt", "after.txt"); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, header()) {
		t.Error("the crypt header changed when the file moved")
	}
}

func TestRemoveFileAndFolder(t *testing.T) {
	ctx := context.Background()
	d, server := newDrive(t, true)
	var counter atomic.Int64
	if _, err := d.upload(ctx, writeLocal(t, []byte("1")), "keep/a", &counter); err != nil {
		t.Fatal(err)
	}
	if _, err := d.upload(ctx, writeLocal(t, []byte("2")), "keep/b", &counter); err != nil {
		t.Fatal(err)
	}
	if err := d.remove(ctx, "keep/a"); err != nil {
		t.Fatalf("remove file: %v", err)
	}
	if err := d.remove(ctx, "keep"); err != nil {
		t.Fatalf("remove folder: %v", err)
	}
	if files := serverFiles(t, server); len(files) != 0 {
		t.Errorf("%d files left on the server", len(files))
	}
}

func TestPlainDriveStoresFilesAsTheyAre(t *testing.T) {
	ctx := context.Background()
	d, server := newDrive(t, false)
	var counter atomic.Int64
	if _, err := d.upload(ctx, writeLocal(t, []byte("open")), "plain.txt", &counter); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(server, "plain.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != "open" {
		t.Errorf("server content = %q", raw)
	}
}

func TestPlainDriveHidesTheControlFolder(t *testing.T) {
	d, server := newDrive(t, false)
	if err := os.MkdirAll(filepath.Join(server, controlFolder), 0o700); err != nil {
		t.Fatal(err)
	}
	items, err := d.list(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Errorf("listing = %+v", items)
	}
}

func TestFailedDownloadLeavesNoPartialFile(t *testing.T) {
	d, _ := newDrive(t, true)
	var counter atomic.Int64
	destination := filepath.Join(t.TempDir(), "out")
	err := d.download(context.Background(), "missing", destination, &counter, "")
	if err == nil {
		t.Fatal("expected an error")
	}
	if _, statErr := os.Stat(destination); !os.IsNotExist(statErr) {
		t.Error("a destination file was left behind")
	}
}

func TestRunCallReportsErrorKinds(t *testing.T) {
	newDrive(t, true)
	arguments, _ := json.Marshal(map[string]string{"drive": driveID(t), "path": "missing"})

	var result callResult
	if err := json.Unmarshal(runCall(1, "stat", arguments), &result); err != nil {
		t.Fatal(err)
	}
	if result.Error == nil || result.Error.Kind != "notFound" {
		t.Errorf("result = %+v", result.Error)
	}
}

func TestCancelledUploadStops(t *testing.T) {
	d, _ := newDrive(t, true)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var counter atomic.Int64
	_, err := d.upload(ctx, writeLocal(t, secretContent), "big", &counter)
	if err == nil {
		t.Fatal("expected the upload to stop")
	}
	if kind := classify(err).Kind; kind != "cancelled" {
		t.Errorf("kind = %q (%v)", kind, err)
	}
}

// A cancel that lands after registration but before the call runs must not be lost.
func TestCancelBeforeTheCallRunsIsKept(t *testing.T) {
	d, server := newDrive(t, true)
	_ = d
	const callID = 7001
	registerCall(callID)
	cancelCall(callID)

	arguments, _ := json.Marshal(map[string]string{
		"drive": driveID(t), "path": "late.bin", "source": writeLocal(t, secretContent),
	})
	var result callResult
	if err := json.Unmarshal(runCall(callID, "upload", arguments), &result); err != nil {
		t.Fatal(err)
	}
	if result.Error == nil || result.Error.Kind != "cancelled" {
		t.Errorf("result = %+v", result.Error)
	}
	if files := serverFiles(t, server); len(files) != 0 {
		t.Errorf("%d files reached the server", len(files))
	}
}
