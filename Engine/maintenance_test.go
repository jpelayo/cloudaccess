// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func saved(t *testing.T, d *drive, name, content string) saveResult {
	t.Helper()
	var counter atomic.Int64
	result, err := d.save(context.Background(), writeLocal(t, []byte(content)), name, "", &counter)
	if err != nil {
		t.Fatalf("save %s: %v", name, err)
	}
	return result
}

func TestADeletedFileCanBeRestored(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	base := saved(t, a, "folder/report.txt", "keep me")
	if err := a.trash(ctx, "folder/report.txt", base.Item.Version); err != nil {
		t.Fatal(err)
	}

	entries, err := a.trashEntries(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].OriginalPath != "folder/report.txt" {
		t.Fatalf("entries = %+v", entries)
	}

	restored, err := a.restoreFromTrash(ctx, entries[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Path != "folder/report.txt" {
		t.Errorf("restored to %q", restored.Path)
	}
	if got := read(t, a, "folder/report.txt"); got != "keep me" {
		t.Errorf("content = %q", got)
	}
	if remaining, _ := a.trashEntries(ctx); len(remaining) != 0 {
		t.Errorf("still in the trash: %+v", remaining)
	}
}

// Entries are read a few at a time, and none may go missing or come back twice.
func TestEveryTrashEntryIsReadOnce(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	want := map[string]bool{}
	for index := range 3*trashReaders + 1 {
		name := fmt.Sprintf("deleted-%d.txt", index)
		base := saved(t, a, name, "gone")
		if err := a.trash(ctx, name, base.Item.Version); err != nil {
			t.Fatal(err)
		}
		want[name] = true
	}

	entries, err := a.trashEntries(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(want) {
		t.Fatalf("%d entries, want %d", len(entries), len(want))
	}
	for _, entry := range entries {
		if !want[entry.OriginalPath] {
			t.Errorf("unexpected or repeated entry: %+v", entry)
		}
		delete(want, entry.OriginalPath)
	}
}

// A partial list would look like files had gone from the trash.
func TestACancelledTrashListingReportsThatInsteadOfAShortList(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	base := saved(t, a, "deleted.txt", "gone")
	if err := a.trash(ctx, "deleted.txt", base.Item.Version); err != nil {
		t.Fatal(err)
	}

	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if entries, err := a.trashEntries(cancelled); err == nil {
		t.Fatalf("a cancelled listing returned %+v", entries)
	}
}

func TestARestoreNeverReplacesAnything(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	base := saved(t, a, "doc.txt", "old")
	if err := a.trash(ctx, "doc.txt", base.Item.Version); err != nil {
		t.Fatal(err)
	}
	saved(t, a, "doc.txt", "new one")

	entries, _ := a.trashEntries(ctx)
	restored, err := a.restoreFromTrash(ctx, entries[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Path == "doc.txt" {
		t.Fatal("the restore took a name that's in use")
	}
	if got := read(t, a, "doc.txt"); got != "new one" {
		t.Errorf("content = %q", got)
	}
	if got := read(t, a, restored.Path); got != "old" {
		t.Errorf("restored content = %q", got)
	}
}

func TestADeletedFolderComesBackWhole(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	saved(t, a, "folder/one.txt", "1")
	saved(t, a, "folder/deep/two.txt", "2")
	if err := a.trash(ctx, "folder", ""); err != nil {
		t.Fatal(err)
	}

	entries, _ := a.trashEntries(ctx)
	if _, err := a.restoreFromTrash(ctx, entries[0].ID); err != nil {
		t.Fatal(err)
	}
	if got := read(t, a, "folder/deep/two.txt"); got != "2" {
		t.Errorf("content = %q", got)
	}
}

func TestRestoringSomethingGoneReportsIt(t *testing.T) {
	a, _, _ := twoDevices(t)
	for _, id := range []string{"no-such-entry", "../vault", ""} {
		if _, err := a.restoreFromTrash(context.Background(), id); !errors.Is(err, errNotInTrash) {
			t.Errorf("%q: err = %v", id, err)
		}
	}
}

// age makes a server folder or file look old.
func age(t *testing.T, location string, by time.Duration) {
	t.Helper()
	old := time.Now().Add(-by)
	if err := os.Chtimes(location, old, old); err != nil {
		t.Fatal(err)
	}
}

func TestMaintenancePurgesOnlyWhatsPastRetention(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	first := saved(t, a, "old.txt", "x")
	second := saved(t, a, "recent.txt", "y")
	if err := a.trash(ctx, "old.txt", first.Item.Version); err != nil {
		t.Fatal(err)
	}
	if err := a.trash(ctx, "recent.txt", second.Item.Version); err != nil {
		t.Fatal(err)
	}
	entries, _ := a.trashEntries(ctx)
	for _, entry := range entries {
		if entry.OriginalPath == "old.txt" {
			age(t, filepath.Join(server, trashFolder, entry.ID), 40*24*time.Hour)
		}
	}

	result, err := a.maintain(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if result.PurgedEntries != 1 {
		t.Errorf("purged %d", result.PurgedEntries)
	}
	remaining, _ := a.trashEntries(ctx)
	if len(remaining) != 1 || remaining[0].OriginalPath != "recent.txt" {
		t.Errorf("remaining = %+v", remaining)
	}
	// Purging twice is harmless.
	if _, err := a.maintain(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestMaintenanceSweepsAbandonedStagingFiles(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	saved(t, a, "file.txt", "x")
	mine := filepath.Join(server, stagingFolder, "device-a", "old-upload")
	theirs := filepath.Join(server, stagingFolder, "device-b", "running-upload")
	for _, file := range []string{mine, theirs} {
		if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		age(t, file, 8*24*time.Hour)
	}

	if _, err := a.maintain(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(mine); !os.IsNotExist(err) {
		t.Error("this device's abandoned upload stayed")
	}
	if _, err := os.Stat(theirs); err != nil {
		t.Errorf("another device's recent upload went: %v", err)
	}
}

func TestRetentionIsSharedByDevices(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	if got, _ := a.policy(ctx); got.TrashRetentionDays != defaultRetentionDays {
		t.Errorf("default = %d", got)
	}
	if err := a.setPolicy(ctx, drivePolicy{TrashRetentionDays: 90}); err != nil {
		t.Fatal(err)
	}
	if got, _ := b.policy(ctx); got.TrashRetentionDays != 90 {
		t.Errorf("the other device sees %d", got)
	}
}

func TestRetiringAVaultStopsEveryDevice(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	if err := a.retireVault(ctx); err != nil {
		t.Fatal(err)
	}
	b.vault.checked = time.Time{}
	var counter atomic.Int64
	if _, err := b.save(ctx, writeLocal(t, []byte("x")), "file.txt", "", &counter); !errors.Is(err, errVaultRetired) {
		t.Fatalf("err = %v", err)
	}
}

func TestVaultDetailsReachTheFilesWithPlainRclone(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	saved(t, a, "secret.txt", "readable with the kit")

	details, err := a.vaultDetails(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if details.Salt == "" || details.VaultID == "" {
		t.Fatalf("details = %+v", details)
	}
	remote := plainRemote(t, server)
	if got := rclone(t, nil, "cat", remote+"secret.txt"); string(got) != "readable with the kit" {
		t.Errorf("content = %q", got)
	}
}

// The Deleted Files window lists folders and only counts files, so entries say which they are.
func TestTrashEntriesSayWhetherTheyAreFolders(t *testing.T) {
	ctx := context.Background()
	d, _, _ := twoDevices(t)
	file := saved(t, d, "note.txt", "a note")
	if err := d.mkdir(ctx, "folder"); err != nil {
		t.Fatal(err)
	}
	if err := d.trash(ctx, "note.txt", file.Item.Version); err != nil {
		t.Fatal(err)
	}
	if err := d.trash(ctx, "folder", ""); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("entries = %+v", entries)
	}
	for _, entry := range entries {
		if entry.IsDirectory != (entry.OriginalPath == "folder") {
			t.Errorf("wrong kind: %+v", entry)
		}
	}
}
