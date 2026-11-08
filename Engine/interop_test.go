// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/rclone/rclone/fs/config/obscure"
	"golang.org/x/net/webdav"
)

const interopPassword = "correct horse"

func requireRclone(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("rclone"); err != nil {
		t.Skip("the rclone command isn't installed")
	}
}

// plainRemote is how someone would reach a drive with stock rclone, using the
// salt from the vault marker, as the recovery kit does.
func plainRemote(t *testing.T, server string) string {
	t.Helper()
	_, marker := readMarker(t, server, 1)
	return fmt.Sprintf(":crypt,remote='%s',password='%s',password2='%s':",
		server, obscure.MustObscure(interopPassword), obscure.MustObscure(marker.Salt))
}

func rclone(t *testing.T, stdin []byte, arguments ...string) []byte {
	t.Helper()
	command := exec.Command("rclone", append(arguments, "--config", "/notfound")...)
	command.Stdin = bytes.NewReader(stdin)
	var errors bytes.Buffer
	command.Stderr = &errors
	output, err := command.Output()
	if err != nil {
		t.Fatalf("rclone %v: %v\n%s", arguments[0], err, errors.String())
	}
	return output
}

func openEncrypted(t *testing.T, id string, config driveConfig) *drive {
	t.Helper()
	config.ID = id
	config.Encrypted = true
	config.VaultPassword = interopPassword
	config.CreateVault = true
	if _, err := openDrive(context.Background(), config); err != nil {
		t.Fatalf("open drive: %v", err)
	}
	t.Cleanup(func() { closeDrive(id) })
	d, err := lookupDrive(id)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestPlainRcloneReadsWhatTheEngineWrote(t *testing.T) {
	requireRclone(t)
	server := t.TempDir()
	d := openEncrypted(t, "interop-read", driveConfig{Kind: "local", RootPath: server})

	var counter atomic.Int64
	content := []byte("written by CloudMount")
	if _, err := d.upload(context.Background(), writeLocal(t, content), "Informes/año 2026.txt", &counter); err != nil {
		t.Fatal(err)
	}

	got := rclone(t, nil, "cat", plainRemote(t, server)+"Informes/año 2026.txt")
	if !bytes.Equal(got, content) {
		t.Errorf("plain rclone read %q", got)
	}
	names := string(rclone(t, nil, "lsf", "-R", plainRemote(t, server)))
	if !strings.Contains(names, "Informes/año 2026.txt") {
		t.Errorf("plain rclone listed %q", names)
	}
	if strings.Contains(names, controlFolder) {
		t.Errorf("plain rclone listed the control folder: %q", names)
	}
}

func TestEngineReadsWhatPlainRcloneWrote(t *testing.T) {
	requireRclone(t)
	server := t.TempDir()
	content := []byte("written by plain rclone")
	d := openEncrypted(t, "interop-write", driveConfig{Kind: "local", RootPath: server})
	rclone(t, content, "rcat", plainRemote(t, server)+"desde rclone/nota.txt")

	var counter atomic.Int64
	destination := filepath.Join(t.TempDir(), "out")
	if err := d.download(context.Background(), "desde rclone/nota.txt", destination, &counter, ""); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, content) {
		t.Errorf("engine read %q", got)
	}
}

// startWebDAV runs a real WebDAV server over a local folder. It uses actual filesystem
// calls, so MKCOL on an existing folder fails as it does on Apache. `rclone serve webdav`
// can't be used here, because it reports success for that, which makes claims meaningless.
func startWebDAV(t *testing.T, folder string) string {
	t.Helper()
	server := httptest.NewServer(&webdav.Handler{
		FileSystem: webdav.Dir(folder),
		LockSystem: webdav.NewMemLS(),
	})
	t.Cleanup(server.Close)
	return server.URL
}

func TestEncryptedDriveOverRealWebDAV(t *testing.T) {
	requireRclone(t)
	ctx := context.Background()
	server := t.TempDir()
	url := startWebDAV(t, server)
	d := openEncrypted(t, "webdav", driveConfig{Kind: "webdav", URL: url})

	var counter atomic.Int64
	content := bytes.Repeat([]byte("over the wire "), 50_000)

	if err := d.mkdir(ctx, "a/b/c"); err != nil {
		t.Fatalf("mkdir with missing parents: %v", err)
	}
	if _, err := d.upload(ctx, writeLocal(t, content), "a/b/c/file.bin", &counter); err != nil {
		t.Fatalf("upload: %v", err)
	}

	listing, err := d.list(ctx, "a/b/c")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(listing) != 1 || listing[0].Path != "a/b/c/file.bin" || listing[0].Size != int64(len(content)) {
		t.Fatalf("listing = %+v", listing)
	}

	partial := filepath.Join(t.TempDir(), "part")
	if err := d.readRange(ctx, "a/b/c/file.bin", 100_000, 5_000, partial, &counter); err != nil {
		t.Fatalf("ranged read: %v", err)
	}
	if got, _ := os.ReadFile(partial); !bytes.Equal(got, content[100_000:105_000]) {
		t.Error("ranged read returned the wrong bytes")
	}

	if err := d.move(ctx, "a/b/c/file.bin", "moved.bin"); err != nil {
		t.Fatalf("move file: %v", err)
	}
	if err := d.move(ctx, "a", "z"); err != nil {
		t.Fatalf("move folder: %v", err)
	}
	destination := filepath.Join(t.TempDir(), "out")
	if err := d.download(ctx, "moved.bin", destination, &counter, ""); err != nil {
		t.Fatalf("download: %v", err)
	}
	if got, _ := os.ReadFile(destination); !bytes.Equal(got, content) {
		t.Error("downloaded content differs")
	}

	if _, err := d.stat(ctx, "missing.bin"); classify(err).Kind != "notFound" {
		t.Errorf("missing item: %v", err)
	}
	if err := d.remove(ctx, "z"); err != nil {
		t.Fatalf("remove folder: %v", err)
	}
	if err := d.remove(ctx, "moved.bin"); err != nil {
		t.Fatalf("remove file: %v", err)
	}
	if files := serverFiles(t, server); len(files) != 0 {
		t.Errorf("%d files left on the server", len(files))
	}
}

// A video-sized file spans many encryption chunks, where the round trip above spans a dozen. The
// second drive opens the vault another device made, as the iPhone does with the Mac's.
func TestABigEncryptedFileReachesAnotherDevice(t *testing.T) {
	requireRclone(t)
	url := startWebDAV(t, t.TempDir())
	checkBigEncryptedRoundTrip(t, driveConfig{Kind: "webdav", URL: url})
}

// checkBigEncryptedRoundTrip uploads from one device and downloads on another, through a vault
// the first one makes on the server the config names.
func checkBigEncryptedRoundTrip(t *testing.T, server driveConfig) {
	t.Helper()
	ctx := context.Background()
	mac := openEncrypted(t, "big-mac", server)

	content := make([]byte, 8<<20+12_345)
	if _, err := rand.Read(content); err != nil {
		t.Fatal(err)
	}
	var counter atomic.Int64
	if _, err := mac.upload(ctx, writeLocal(t, content), "Vídeos/clip.mov", &counter); err != nil {
		t.Fatalf("upload: %v", err)
	}

	config := server
	config.ID, config.Encrypted, config.VaultPassword = "big-phone", true, interopPassword
	if _, err := openDrive(ctx, config); err != nil {
		t.Fatalf("open the vault from a second device: %v", err)
	}
	t.Cleanup(func() { closeDrive("big-phone") })
	phone, err := lookupDrive("big-phone")
	if err != nil {
		t.Fatal(err)
	}
	listed, err := phone.stat(ctx, "Vídeos/clip.mov")
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if listed.Size != int64(len(content)) {
		t.Errorf("listed size %d, want %d", listed.Size, len(content))
	}
	destination := filepath.Join(t.TempDir(), "clip.mov")
	if err := phone.download(ctx, "Vídeos/clip.mov", destination, &counter, ""); err != nil {
		t.Fatalf("download: %v", err)
	}
	if got, _ := os.ReadFile(destination); !bytes.Equal(got, content) {
		t.Errorf("downloaded %d bytes that differ from the %d uploaded", len(got), len(content))
	}
}

func TestWebDAVListingsCarryETagsThatChangeOnEdit(t *testing.T) {
	requireRclone(t)
	ctx := context.Background()
	server := t.TempDir()
	url := startWebDAV(t, server)
	d := openEncrypted(t, "webdav-etags", driveConfig{Kind: "webdav", URL: url})
	var counter atomic.Int64

	if _, err := d.upload(ctx, writeLocal(t, []byte("first")), "notes/a.txt", &counter); err != nil {
		t.Fatal(err)
	}
	listed, err := d.list(ctx, "notes")
	if err != nil {
		t.Fatal(err)
	}
	if len(listed) != 1 || listed[0].Version == "" || listed[0].Path != "notes/a.txt" || listed[0].Size != 5 {
		t.Fatalf("listing = %+v", listed)
	}

	if _, err := d.upload(ctx, writeLocal(t, []byte("other")), "notes/a.txt", &counter); err != nil {
		t.Fatal(err)
	}
	edited, err := d.stat(ctx, "notes/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	if edited.Version == listed[0].Version {
		t.Error("a same-size edit didn't change the ETag")
	}

	root, err := d.list(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(root) != 1 || root[0].Path != "notes" || !root[0].IsDirectory {
		t.Errorf("the control folder should be hidden: %+v", root)
	}
	if item, err := d.stat(ctx, "notes"); err != nil || !item.IsDirectory {
		t.Errorf("folder stat: %+v, %v", item, err)
	}
}

func TestUnreachableServerIsAConnectionError(t *testing.T) {
	t.Cleanup(func() { closeDrive("unreachable") })
	_, err := openDrive(context.Background(), driveConfig{
		ID: "unreachable", Kind: "webdav", URL: "http://127.0.0.1:1",
		Encrypted: true, VaultPassword: interopPassword,
	})
	if err == nil {
		t.Fatal("expected an error")
	}
	if kind := classify(err).Kind; kind != "unreachable" {
		t.Errorf("kind = %q (%v)", kind, err)
	}
}
