// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// testServer picks the protocol for the commit tests. Nil means WebDAV.
var testServer func(*testing.T, string) driveConfig

// twoDevices opens the same encrypted server folder as two separate devices.
func twoDevices(t *testing.T) (a, b *drive, server string) {
	t.Helper()
	requireRclone(t)
	server = t.TempDir()
	base := driveConfig{Kind: "webdav"}
	if testServer != nil {
		base = testServer(t, server)
	} else {
		base.URL = startWebDAV(t, server)
	}
	id := driveID(t)
	first, second := base, base
	first.DeviceID, first.DeviceName = "device-a", "MacBook"
	second.DeviceID, second.DeviceName = "device-b", "iMac"
	a = openEncrypted(t, id+"-a", first)
	b = openEncrypted(t, id+"-b", second)
	return a, b, server
}

func read(t *testing.T, d *drive, p string) string {
	t.Helper()
	var counter atomic.Int64
	destination := filepath.Join(t.TempDir(), "out")
	if err := d.download(context.Background(), p, destination, &counter, ""); err != nil {
		t.Fatalf("download %s: %v", p, err)
	}
	content, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func TestSaveCreatesAndReplacesFromTheBaseVersion(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	var counter atomic.Int64

	first, err := a.save(ctx, writeLocal(t, []byte("one")), "file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if first.ConflictPath != "" || first.Item.Version == "" {
		t.Fatalf("first save = %+v", first)
	}
	second, err := a.save(ctx, writeLocal(t, []byte("two")), "file.txt", first.Item.Version, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if second.ConflictPath != "" {
		t.Fatalf("second save = %+v", second)
	}
	if got := read(t, a, "file.txt"); got != "two" {
		t.Errorf("content = %q", got)
	}
}

func TestAPeersSaveIsNeverOverwritten(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64

	base, err := a.save(ctx, writeLocal(t, []byte("original")), "shared.docx", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.save(ctx, writeLocal(t, []byte("from B")), "shared.docx", base.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}

	// A still believes it's editing the original.
	result, err := a.save(ctx, writeLocal(t, []byte("from A")), "shared.docx", base.Item.Version, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictPath == "" {
		t.Fatal("no conflict was reported")
	}
	if !strings.Contains(result.ConflictPath, "conflict from MacBook") || !strings.HasSuffix(result.ConflictPath, ".docx") {
		t.Errorf("conflict name = %q", result.ConflictPath)
	}
	if got := read(t, a, "shared.docx"); got != "from B" {
		t.Errorf("the server's version should keep the name: %q", got)
	}
	if got := read(t, a, result.ConflictPath); got != "from A" {
		t.Errorf("conflict copy = %q", got)
	}
}

func TestANewFileOnATakenNameBecomesAConflictCopy(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	if _, err := a.save(ctx, writeLocal(t, []byte("A first")), "same.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	result, err := b.save(ctx, writeLocal(t, []byte("B second")), "same.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictPath == "" {
		t.Fatal("no conflict was reported")
	}
	if got := read(t, b, "same.txt"); got != "A first" {
		t.Errorf("content = %q", got)
	}
}

func TestAnEditOfAFileAPeerDeletedIsPutBack(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	base, err := a.save(ctx, writeLocal(t, []byte("original")), "folder/file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if err := b.remove(ctx, "folder"); err != nil {
		t.Fatal(err)
	}

	result, err := a.save(ctx, writeLocal(t, []byte("still editing")), "folder/file.txt", base.Item.Version, &counter)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictPath != "" {
		t.Errorf("result = %+v", result)
	}
	if got := read(t, a, "folder/file.txt"); got != "still editing" {
		t.Errorf("content = %q", got)
	}
}

// Both devices start from the same version at the same moment, over and over. Every save
// must survive, whichever device wins.
func TestSimultaneousSavesKeepBothVersions(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64

	for run := range 25 {
		name := fmt.Sprintf("race-%d.txt", run)
		base, err := a.save(ctx, writeLocal(t, []byte("base")), name, "", &counter)
		if err != nil {
			t.Fatal(err)
		}
		fromA, fromB := fmt.Sprintf("A %d", run), fmt.Sprintf("B %d", run)
		sourceA, sourceB := writeLocal(t, []byte(fromA)), writeLocal(t, []byte(fromB))

		var wait sync.WaitGroup
		var resultA, resultB saveResult
		var errA, errB error
		wait.Add(2)
		go func() {
			defer wait.Done()
			resultA, errA = a.save(ctx, sourceA, name, base.Item.Version, &counter)
		}()
		go func() {
			defer wait.Done()
			resultB, errB = b.save(ctx, sourceB, name, base.Item.Version, &counter)
		}()
		wait.Wait()
		if errA != nil || errB != nil {
			t.Fatalf("run %d: %v, %v", run, errA, errB)
		}

		conflicts := 0
		found := map[string]bool{read(t, a, name): true}
		for _, result := range []saveResult{resultA, resultB} {
			if result.ConflictPath != "" {
				conflicts++
				found[read(t, a, result.ConflictPath)] = true
			}
		}
		if conflicts != 1 {
			t.Errorf("run %d: %d conflicts, want exactly 1", run, conflicts)
		}
		if !found[fromA] || !found[fromB] {
			t.Errorf("run %d lost a save: %v", run, found)
		}
	}
}

func TestAnAbandonedClaimIsTakenOver(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	var counter atomic.Int64
	base, err := a.save(ctx, writeLocal(t, []byte("x")), "file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}

	// A device died holding this claim, long enough ago to count as abandoned.
	claim := filepath.Join(server, claimPath(a.rawFile("file.txt")))
	if err := os.MkdirAll(claim, 0o700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * claimStaleAfter)
	if err := os.Chtimes(claim, old, old); err != nil {
		t.Fatal(err)
	}

	if _, err := a.save(ctx, writeLocal(t, []byte("y")), "file.txt", base.Item.Version, &counter); err != nil {
		t.Fatalf("save after a stale claim: %v", err)
	}
	if got := read(t, a, "file.txt"); got != "y" {
		t.Errorf("content = %q", got)
	}
}

func TestAFreshClaimBlocksAndReportsBusy(t *testing.T) {
	a, _, _ := twoDevices(t)
	raw := a.rawFile("busy.txt")
	claim, err := acquireClaim(context.Background(), a.server, raw)
	if err != nil {
		t.Fatal(err)
	}
	defer releaseClaim(a.server, claim)

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if _, err := acquireClaim(ctx, a.server, raw); err == nil {
		t.Fatal("a held claim was acquired twice")
	}
}

func TestNoClaimOrStagingFileIsLeftBehind(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	var counter atomic.Int64
	if _, err := a.save(ctx, writeLocal(t, []byte("x")), "file.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	for _, folder := range []string{claimsFolder, stagingFolder + "/device-a"} {
		entries, _ := os.ReadDir(filepath.Join(server, folder))
		if len(entries) != 0 {
			t.Errorf("%s still holds %d entries", folder, len(entries))
		}
	}
}

func TestMoveRefusesToReplaceAnything(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	var counter atomic.Int64
	for _, name := range []string{"a.txt", "b.txt"} {
		if _, err := a.save(ctx, writeLocal(t, []byte(name)), name, "", &counter); err != nil {
			t.Fatal(err)
		}
	}
	// The kind matters as much as the refusal: macOS renames one of them on a taken name, and
	// stops trying for good on anything it can't tell apart from a broken drive.
	if _, err := a.moveItem(ctx, "a.txt", "b.txt", ""); err == nil {
		t.Fatal("the move replaced an existing file")
	} else if kind := classify(err).Kind; kind != "alreadyExists" {
		t.Fatalf("a taken name came back as %q: %v", kind, err)
	}
	if got := read(t, a, "b.txt"); got != "b.txt" {
		t.Errorf("content = %q", got)
	}

	moved, err := a.moveItem(ctx, "a.txt", "new/c.txt", "")
	if err != nil {
		t.Fatal(err)
	}
	if moved.Path != "new/c.txt" {
		t.Errorf("moved = %+v", moved)
	}
}

func TestDeleteGoesToTrashAndCanBeRecovered(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	var counter atomic.Int64
	base, err := a.save(ctx, writeLocal(t, []byte("keep me")), "report.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.trash(ctx, "report.txt", base.Item.Version); err != nil {
		t.Fatal(err)
	}
	if _, err := a.stat(ctx, "report.txt"); classify(err).Kind != "notFound" {
		t.Errorf("after trash: %v", err)
	}

	entries, err := os.ReadDir(filepath.Join(server, trashFolder))
	if err != nil || len(entries) != 1 {
		t.Fatalf("trash entries = %d, %v", len(entries), err)
	}
	entry := filepath.Join(server, trashFolder, entries[0].Name())
	if _, err := os.Stat(filepath.Join(entry, "item")); err != nil {
		t.Errorf("the item isn't in the trash: %v", err)
	}
	meta, err := os.ReadFile(filepath.Join(entry, "meta"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(meta), "report.txt") {
		t.Error("the trash metadata exposes the original name on an encrypted drive")
	}
}

func TestDeletingAPeersNewerVersionIsRefused(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	base, err := a.save(ctx, writeLocal(t, []byte("old")), "doc.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := b.save(ctx, writeLocal(t, []byte("newer")), "doc.txt", base.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}
	err = a.trash(ctx, "doc.txt", base.Item.Version)
	if classify(err).Kind != "versionMismatch" {
		t.Fatalf("got %v", err)
	}
	if got := read(t, a, "doc.txt"); got != "newer" {
		t.Errorf("content = %q", got)
	}
}

func TestDeletingAFolderKeepsEverythingInsideIt(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	var counter atomic.Int64
	if _, err := a.save(ctx, writeLocal(t, []byte("x")), "folder/inner.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	if err := a.trash(ctx, "folder", ""); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(filepath.Join(server, trashFolder))
	if len(entries) != 1 {
		t.Fatalf("trash entries = %d", len(entries))
	}
	inside, _ := os.ReadDir(filepath.Join(server, trashFolder, entries[0].Name(), "item"))
	if len(inside) != 1 {
		t.Errorf("the trashed folder holds %d items", len(inside))
	}
}

func TestConflictNamesStayShortAndKeepTheExtension(t *testing.T) {
	when := time.Date(2026, 11, 5, 0, 0, 0, 0, time.UTC)
	if got := conflictName("Report.docx", "MacBook", when, 1); got != "Report (conflict from MacBook 2026-11-05).docx" {
		t.Errorf("name = %q", got)
	}
	if got := conflictName("Report.docx", "MacBook", when, 2); got != "Report (conflict from MacBook 2026-11-05 2).docx" {
		t.Errorf("name = %q", got)
	}
	long := conflictName(strings.Repeat("a", 300)+".pdf", "MacBook", when, 1)
	if len(long) > 140 || !strings.HasSuffix(long, ".pdf") {
		t.Errorf("length %d, name %q", len(long), long)
	}
}

// macOS reads a package's type from the name, so a copy that split the two extensions would
// come back as something nothing can open.
func TestAConflictCopyOfAPackageStaysAPackage(t *testing.T) {
	when := time.Date(2026, 11, 5, 0, 0, 0, 0, time.UTC)
	if got := conflictName("Report.numbers.pkgf", "MacBook", when, 1); got != "Report (conflict from MacBook 2026-11-05).numbers.pkgf" {
		t.Errorf("name = %q", got)
	}
	if got := conflictName("Report.numbers.pkgf", "MacBook", when, 2); got != "Report (conflict from MacBook 2026-11-05 2).numbers.pkgf" {
		t.Errorf("name = %q", got)
	}
	if got := conflictName("Plain.pkgf", "MacBook", when, 1); got != "Plain (conflict from MacBook 2026-11-05).pkgf" {
		t.Errorf("name = %q", got)
	}
	long := conflictName(strings.Repeat("a", 300)+".numbers.pkgf", "MacBook", when, 1)
	if len(long) > 140 || !strings.HasSuffix(long, ".numbers.pkgf") {
		t.Errorf("length %d, name %q", len(long), long)
	}
}
