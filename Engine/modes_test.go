// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

// openSFTPAs opens one more connection to the same test server, as its own drive and device.
func openSFTPAs(t *testing.T, config driveConfig, name, device, mode string) *drive {
	t.Helper()
	config.ID = driveID(t) + "-" + name
	config.DeviceID = device
	config.DeviceName = device
	config.Mode = mode
	if _, err := openDrive(context.Background(), config); err != nil {
		t.Fatalf("open %s: %v", name, err)
	}
	t.Cleanup(func() { closeDrive(config.ID) })
	d, err := lookupDrive(config.ID)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// leftovers lists what a drive in a mode without a control folder must never leave in its root.
func leftovers(t *testing.T, folder string) []string {
	t.Helper()
	entries, err := os.ReadDir(folder)
	if err != nil {
		t.Fatal(err)
	}
	var found []string
	for _, entry := range entries {
		if entry.Name() == controlFolder || strings.HasPrefix(entry.Name(), ".cm-") {
			found = append(found, entry.Name())
		}
	}
	return found
}

func readDisk(t *testing.T, file string) string {
	t.Helper()
	content, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func TestUnsafeModeLeavesNothingOnTheServer(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	d := openSFTPAs(t, startSFTP(t, folder), "unsafe", "device-a", "unsafe")
	var counter atomic.Int64

	first, err := d.save(ctx, writeLocal(t, []byte("first")), "notes/a.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	second, err := d.save(ctx, writeLocal(t, []byte("second, longer")), "notes/a.txt", first.Item.Version, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if second.ConflictPath != "" {
		t.Fatalf("own edit became a conflict copy: %+v", second)
	}
	moved, err := d.moveItem(ctx, "notes/a.txt", "notes/b.txt", second.Item.Version)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.mkdirWith(ctx, "empty", time.Time{}); err != nil {
		t.Fatal(err)
	}
	if err := d.trash(ctx, "notes/b.txt", moved.Version); err != nil {
		t.Fatal(err)
	}
	if err := d.trash(ctx, "empty", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := d.maintain(ctx); err != nil {
		t.Fatal(err)
	}

	if found := leftovers(t, folder); len(found) != 0 {
		t.Errorf("left on the server: %v", found)
	}
	for _, gone := range []string{"notes/a.txt", "notes/b.txt", "empty"} {
		if _, err := os.Stat(filepath.Join(folder, gone)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s is still there: %v", gone, err)
		}
	}
}

// An upload that never reaches its final move must leave the old file exactly as it was, and
// its hidden upload file must never show up as a file.
func TestAnUnsafeUploadThatNeverLandsLeavesTheOldFileWhole(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	d := openSFTPAs(t, startSFTP(t, folder), "unsafe", "device-a", "unsafe")
	var counter atomic.Int64
	if _, err := d.save(ctx, writeLocal(t, []byte("the old file")), "doc.txt", "", &counter); err != nil {
		t.Fatal(err)
	}

	staged, err := d.stage(ctx, writeLocal(t, []byte("a new version that never lands")), &counter)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(staged.Staged, ".cm-") || strings.Contains(staged.Staged, "/") {
		t.Fatalf("staged at %q, not as a hidden file in the root", staged.Staged)
	}
	if got := readDisk(t, filepath.Join(folder, "doc.txt")); got != "the old file" {
		t.Errorf("doc.txt = %q", got)
	}
	items, err := d.list(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if strings.HasPrefix(item.Path, ".cm-") {
			t.Errorf("listing shows the upload file %q", item.Path)
		}
	}
	d.discardStage(staged.Staged)
	if found := leftovers(t, folder); len(found) != 0 {
		t.Errorf("left on the server: %v", found)
	}
}

func TestAnUnsafeSaveOverAPeersVersionKeepsBoth(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	d := openSFTPAs(t, startSFTP(t, folder), "unsafe", "device-a", "unsafe")
	var counter atomic.Int64
	saved, err := d.save(ctx, writeLocal(t, []byte("ours, first")), "doc.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	// A peer's save, with a different size so the version can't match by chance.
	if err := os.WriteFile(filepath.Join(folder, "doc.txt"), []byte("the peer's newer version"), 0o600); err != nil {
		t.Fatal(err)
	}

	result, err := d.save(ctx, writeLocal(t, []byte("ours, second")), "doc.txt", saved.Item.Version, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictPath == "" {
		t.Fatal("the peer's version was replaced")
	}
	if got := readDisk(t, filepath.Join(folder, "doc.txt")); got != "the peer's newer version" {
		t.Errorf("doc.txt = %q", got)
	}
	if got := readDisk(t, filepath.Join(folder, result.ConflictPath)); got != "ours, second" {
		t.Errorf("conflict copy = %q", got)
	}
	if found := leftovers(t, folder); len(found) != 0 {
		t.Errorf("left on the server: %v", found)
	}
}

func TestAnUnsafeDeleteOfAPeersVersionIsRefused(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	d := openSFTPAs(t, startSFTP(t, folder), "unsafe", "device-a", "unsafe")
	var counter atomic.Int64
	saved, err := d.save(ctx, writeLocal(t, []byte("ours")), "doc.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, "doc.txt"), []byte("the peer's edit"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := d.trash(ctx, "doc.txt", saved.Item.Version); !errors.Is(err, errPeerChanged) {
		t.Fatalf("delete of a peer's version: %v", err)
	}
	if got := readDisk(t, filepath.Join(folder, "doc.txt")); got != "the peer's edit" {
		t.Errorf("doc.txt = %q", got)
	}
}

func TestListingsNeverShowReservedNames(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	for _, name := range []string{".cm-device-b-1-x.part", "kept.txt"} {
		if err := os.WriteFile(filepath.Join(folder, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	d := openSFTPAs(t, startSFTP(t, folder), "safe", "device-a", "safe")
	items, err := d.list(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, item := range items {
		names = append(names, item.Path)
	}
	if !slices.Equal(names, []string{"kept.txt"}) {
		t.Errorf("listing = %v", names)
	}
}

func TestUnsafeModeIsOnlyForSFTP(t *testing.T) {
	_, err := openDrive(context.Background(), driveConfig{
		ID: driveID(t), Kind: "webdav", URL: "https://127.0.0.1:1/cloudmount-test", Mode: "unsafe",
	})
	if !errors.Is(err, errUnsafeNeedsSFTP) {
		t.Fatalf("open = %v", err)
	}
}

func TestUnsafeModeRefusesWhatNeedsTheTrash(t *testing.T) {
	_ = openSFTPAs(t, startSFTP(t, t.TempDir()), "unsafe", "device-a", "unsafe")
	for _, method := range []string{"setPolicy", "trashRestore", "trashPurge", "retireVault"} {
		_, err := dispatch(context.Background(), method, []byte(fmt.Sprintf(`{"drive":%q,"path":"x","length":1}`, driveID(t)+"-unsafe")), nil)
		if !errors.Is(err, errUnsafeKeepsNoTrash) {
			t.Errorf("%s = %v", method, err)
		}
	}
}

func TestReadOnlyModeWritesNothing(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	_ = openSFTPAs(t, startSFTP(t, folder), "readonly", "device-a", "readOnly")
	for _, method := range []string{"stage", "commit", "mkdir", "move", "trash", "trashPurge", "maintain", "probe", "cleanControlFolder"} {
		_, err := dispatch(ctx, method, []byte(fmt.Sprintf(`{"drive":%q,"path":"x"}`, driveID(t)+"-readonly")), nil)
		if !errors.Is(err, errReadOnly) {
			t.Errorf("%s = %v", method, err)
		}
	}
	if found := leftovers(t, folder); len(found) != 0 {
		t.Errorf("left on the server: %v", found)
	}
}

// Safe mode makes the control folder, as a Safe device on another Mac would, so the clean-up has
// something real to clear.
func fillControlFolder(t *testing.T, config driveConfig) {
	t.Helper()
	ctx := context.Background()
	safe := openSFTPAs(t, config, "filler", "device-b", "safe")
	var counter atomic.Int64
	saved, err := safe.save(ctx, writeLocal(t, []byte("deleted later")), "gone.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if err := safe.trash(ctx, "gone.txt", saved.Item.Version); err != nil {
		t.Fatal(err)
	}
	if _, err := safe.maintain(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestCleaningAPlainDriveRemovesTheWholeControlFolder(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	config := startSFTP(t, folder)
	fillControlFolder(t, config)
	d := openSFTPAs(t, config, "unsafe", "device-a", "unsafe")

	found, err := d.controlFolderContents(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !found.Exists || found.TrashItems != 1 || found.HasVault || found.SafeDevices != 1 || found.OtherEntries == 0 {
		t.Fatalf("contents = %+v", found)
	}
	if _, err := d.cleanControlFolder(ctx); err != nil {
		t.Fatal(err)
	}
	if left := leftovers(t, folder); len(left) != 0 {
		t.Errorf("left on the server: %v", left)
	}
}

func TestCleaningAnEncryptedDriveKeepsItsVault(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	config := startSFTP(t, folder)
	config.Encrypted, config.VaultPassword, config.CreateVault = true, "correct horse", true
	fillControlFolder(t, config)
	config.CreateVault = false
	d := openSFTPAs(t, config, "unsafe", "device-a", "unsafe")
	var counter atomic.Int64
	if _, err := d.save(ctx, writeLocal(t, []byte("still readable")), "kept.txt", "", &counter); err != nil {
		t.Fatal(err)
	}

	if _, err := d.cleanControlFolder(ctx); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(folder, controlFolder))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "vault" {
		t.Errorf("control folder holds %v, not just the vault", entries)
	}
	// The drive still opens and reads, which only the vault's salt allows.
	again := openSFTPAs(t, config, "again", "device-c", "safe")
	destination := filepath.Join(t.TempDir(), "kept.txt")
	if err := again.download(ctx, "kept.txt", destination, &counter, ""); err != nil {
		t.Fatal(err)
	}
	if got := readDisk(t, destination); got != "still readable" {
		t.Errorf("kept.txt = %q", got)
	}
}

func TestCleaningWaitsForADeviceThatIsSaving(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	config := startSFTP(t, folder)
	safe := openSFTPAs(t, config, "safe", "device-b", "safe")
	held, err := acquireClaim(ctx, safe.server, safe.rawFile("busy.txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer releaseClaim(safe.server, held)

	d := openSFTPAs(t, config, "unsafe", "device-a", "unsafe")
	if _, err := d.cleanControlFolder(ctx); !errors.Is(err, errControlFolderBusy) {
		t.Fatalf("clean while a claim is held = %v", err)
	}
	if _, err := os.Stat(filepath.Join(folder, claimsFolder)); err != nil {
		t.Errorf("the claim was removed: %v", err)
	}
}

func TestSafeModeNeverCleansItsOwnControlFolder(t *testing.T) {
	d := openSFTPAs(t, startSFTP(t, t.TempDir()), "safe", "device-a", "safe")
	if _, err := d.cleanControlFolder(context.Background()); !errors.Is(err, errSafeNeedsControlFolder) {
		t.Fatalf("clean in Safe mode = %v", err)
	}
}

// After a crash, a device clears only its own upload files, and only once no upload could still
// be running. Another device's are counted, never touched.
func TestUnsafeMaintenanceClearsOnlyThisDevicesOldUploads(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	old := time.Now().Add(-ownStagingLifetime - time.Hour).Unix()
	names := map[string]bool{
		fmt.Sprintf(".cm-device-a-%d-%s.part", old, uuid.NewString()):               false,
		fmt.Sprintf(".cm-device-a-%d-%s.part", time.Now().Unix(), uuid.NewString()): true,
		fmt.Sprintf(".cm-device-b-%d-%s.part", old, uuid.NewString()):               true,
	}
	for name := range names {
		if err := os.WriteFile(filepath.Join(folder, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	d := openSFTPAs(t, startSFTP(t, folder), "unsafe", "device-a", "unsafe")
	result, err := d.maintain(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if result.SweptFiles != 1 || result.OtherDevicesUploads != 1 {
		t.Errorf("result = %+v", result)
	}
	for name, kept := range names {
		_, err := os.Stat(filepath.Join(folder, name))
		if (err == nil) != kept {
			t.Errorf("%s: kept = %v, want %v", name, err == nil, kept)
		}
	}
	if _, err := os.Stat(filepath.Join(folder, controlFolder)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("maintenance made a control folder: %v", err)
	}
}
