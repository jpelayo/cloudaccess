// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/net/webdav"
)

// These tests came from the second assessment. Each failed before its fix.

func plainDAV(t *testing.T, folder string) *drive {
	t.Helper()
	return openSFTP(t, driveConfig{Kind: "webdav", URL: startWebDAV(t, folder)})
}

func oldFile(t *testing.T, age time.Duration) string {
	t.Helper()
	source := filepath.Join(t.TempDir(), "old.txt")
	if err := os.WriteFile(source, []byte("old document"), 0o600); err != nil {
		t.Fatal(err)
	}
	when := time.Now().Add(-age)
	if err := os.Chtimes(source, when, when); err != nil {
		t.Fatal(err)
	}
	return source
}

func onBothServers(t *testing.T, run func(t *testing.T, d *drive, folder string)) {
	t.Run("WebDAV", func(t *testing.T) {
		folder := t.TempDir()
		run(t, plainDAV(t, folder), folder)
	})
	t.Run("SFTP", func(t *testing.T) {
		folder := t.TempDir()
		run(t, openSFTP(t, startSFTP(t, folder)), folder)
	})
}

// MARK: Claims (R02)

func TestAnOldHolderCantDeleteItsSuccessorsClaim(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		ctx := context.Background()
		old, err := acquireClaim(ctx, d.server, "some/file")
		if err != nil {
			t.Fatal(err)
		}
		// A delayed observer moves the claim away, which a takeover can do.
		if err := d.server.moveRaw(ctx, claimPath("some/file"), claimsFolder+"/stale-test", true, false); err != nil {
			t.Fatal(err)
		}
		successor, err := acquireClaim(ctx, d.server, "some/file")
		if err != nil {
			t.Fatal(err)
		}
		releaseClaim(d.server, old)
		if err := successor.stillOwned(ctx, d.server); err != nil {
			t.Fatalf("the old holder's release destroyed the successor's claim: %v", err)
		}
	})
}

// changingServer swaps a claim for a fresh one in the moment a takeover has judged it old.
type changingServer struct {
	rawServer
	claim   string
	swapped atomic.Bool
}

func (s *changingServer) createExclusive(ctx context.Context, rawPath string) (bool, error) {
	created, err := s.rawServer.createExclusive(ctx, rawPath)
	if strings.Contains(rawPath, "/now-") && s.swapped.CompareAndSwap(false, true) {
		// The clock probe is what comes between the two reads of the claim.
		_ = s.rawServer.removeAll(ctx, s.claim)
		time.Sleep(1100 * time.Millisecond)
		if _, err := s.rawServer.createExclusive(ctx, s.claim); err != nil {
			return false, err
		}
	}
	return created, err
}

func TestATakeoverLeavesAClaimThatChangedWhileItLooked(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	claim := claimPath("some/file")
	if _, err := acquireClaim(ctx, d.server, "some/file"); err != nil {
		t.Fatal(err)
	}
	aged := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(folder, claim), aged, aged); err != nil {
		t.Fatal(err)
	}
	takeOverIfStale(ctx, &changingServer{rawServer: d.server, claim: claim}, claim)
	if _, err := d.server.statRaw(ctx, claim); err != nil {
		t.Fatalf("a takeover moved a fresh claim away: %v", err)
	}
}

// MARK: Lost answers (R01)

// heldServer stops a commit's final move, so a test can act while it's on its way.
type heldServer struct {
	rawServer
	reached chan struct{}
	proceed chan struct{}
	fail    error
}

func (s *heldServer) moveRaw(ctx context.Context, from, to string, folder, overwrite bool) error {
	if !strings.HasPrefix(from, stagingFolder) {
		return s.rawServer.moveRaw(ctx, from, to, folder, overwrite)
	}
	close(s.reached)
	<-s.proceed
	if s.fail != nil {
		return s.fail
	}
	return s.rawServer.moveRaw(ctx, from, to, folder, overwrite)
}

func TestCancellingCantAbandonACommitsFinalMove(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		var counter atomic.Int64
		held := &heldServer{rawServer: d.server, reached: make(chan struct{}), proceed: make(chan struct{})}
		real := d.server
		d.server = held
		defer func() { d.server = real }()

		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		returned := make(chan struct{})
		go func() {
			defer close(returned)
			_, _ = d.save(ctx, writeLocal(t, []byte("mine")), "file.txt", "", &counter)
		}()
		<-held.reached
		cancel()
		select {
		case <-returned:
			t.Fatal("the save returned while its move was still on its way")
		case <-time.After(300 * time.Millisecond):
		}
		close(held.proceed)
		<-returned
		if _, found, err := d.exists(context.Background(), "file.txt"); err != nil || !found {
			t.Fatalf("the move should have finished: %v %v", found, err)
		}
	})
}

func TestALostAnswerKeepsTheClaimSoNoPeerCanCommit(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		var counter atomic.Int64
		ctx := context.Background()
		held := &heldServer{
			rawServer: d.server, reached: make(chan struct{}), proceed: make(chan struct{}), fail: errServerGone,
		}
		close(held.proceed)
		real := d.server
		d.server = held
		_, err := d.save(ctx, writeLocal(t, []byte("mine")), "file.txt", "", &counter)
		d.server = real
		if !errors.Is(err, errResultUnknown) {
			t.Fatalf("expected an unknown result, got %v", err)
		}
		if got := classify(err).Kind; got != "unreachable" {
			t.Fatalf("an unknown result is a connection problem, got %q", got)
		}
		if _, err := d.server.statRaw(ctx, claimPath(d.rawFile("file.txt"))); err != nil {
			t.Fatalf("the claim should stay until it expires: %v", err)
		}
	})
}

func TestAKnownFailureStillReleasesTheClaim(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		var counter atomic.Int64
		ctx := context.Background()
		held := &heldServer{
			rawServer: d.server, reached: make(chan struct{}), proceed: make(chan struct{}),
			fail: statusError(http.StatusForbidden),
		}
		close(held.proceed)
		real := d.server
		d.server = held
		_, _ = d.save(ctx, writeLocal(t, []byte("mine")), "file.txt", "", &counter)
		d.server = real
		if _, err := d.server.statRaw(ctx, claimPath(d.rawFile("file.txt"))); !isNotFound(err) {
			t.Fatalf("a refused move has a known result, so its claim goes: %v", err)
		}
	})
}

// MARK: Staging (R03)

func TestAFreshUploadOfAnOldFileSurvivesMaintenance(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		ctx := context.Background()
		var counter atomic.Int64
		staged, err := d.stageUpload(ctx, oldFile(t, 90*24*time.Hour), &counter)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.maintain(ctx); err != nil {
			t.Fatal(err)
		}
		if _, err := d.server.statRaw(ctx, staged); err != nil {
			t.Fatalf("maintenance removed a staging file uploaded a moment ago: %v", err)
		}
	})
}

func TestAStagedFilesAgeIsTheLaterOfItsUploadAndItsTime(t *testing.T) {
	now := time.Now()
	recent := fmt.Sprintf("%d-id", now.Add(-time.Hour).Unix())
	old := fmt.Sprintf("%d-id", now.Add(-40*24*time.Hour).Unix())
	if age := stagingAge(rawEntry{Name: recent, Modified: now.Add(-90 * 24 * time.Hour)}, now); age > 2*time.Hour {
		t.Fatalf("an old document made a live upload look old: %v", age)
	}
	if age := stagingAge(rawEntry{Name: old, Modified: now.Add(-time.Hour)}, now); age > 2*time.Hour {
		t.Fatalf("a wrong clock made a live upload look old: %v", age)
	}
	if age := stagingAge(rawEntry{Name: old, Modified: now.Add(-40 * 24 * time.Hour)}, now); age < 39*24*time.Hour {
		t.Fatalf("an abandoned upload looks new: %v", age)
	}
	if age := stagingAge(rawEntry{Name: "no-time-here", Modified: now.Add(-40 * 24 * time.Hour)}, now); age < 39*24*time.Hour {
		t.Fatalf("a file from an older build should go by its time: %v", age)
	}
}

// MARK: Retention (R04)

func trashOldItem(t *testing.T, d *drive, folder string, days int) string {
	t.Helper()
	return trashAgedItem(t, d, folder, time.Duration(days)*24*time.Hour)
}

func trashAgedItem(t *testing.T, d *drive, folder string, old time.Duration) string {
	t.Helper()
	ctx := context.Background()
	var counter atomic.Int64
	result, err := d.save(ctx, writeLocal(t, []byte("keep me")), "keep.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.trash(ctx, "keep.txt", result.Item.Version); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(ctx)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries %v %v", entries, err)
	}
	entry := filepath.Join(folder, ".cloudmount", "trash", entries[0].ID)
	aged := time.Now().Add(-old)
	if err := os.Chtimes(entry, aged, aged); err != nil {
		t.Fatal(err)
	}
	return entries[0].ID
}

func TestUncertainRetentionNeverPurges(t *testing.T) {
	for name, content := range map[string]string{
		"truncated": `{"trashRetent`,
		"not json":  `hello`,
		"zero":      `{"trashRetentionDays":0}`,
		"negative":  `{"trashRetentionDays":-5}`,
		"huge":      `{"trashRetentionDays":200000}`,

		"seconds too short":    `{"trashRetentionDays":1,"trashRetentionSeconds":5}`,
		"negative seconds":     `{"trashRetentionDays":1,"trashRetentionSeconds":-60}`,
		"seconds not a number": `{"trashRetentionDays":1,"trashRetentionSeconds":"soon"}`,
		"days under seconds":   `{"trashRetentionDays":1,"trashRetentionSeconds":864000}`,
	} {
		t.Run(name, func(t *testing.T) {
			folder := t.TempDir()
			d := openSFTP(t, startSFTP(t, folder))
			ctx := context.Background()
			if err := d.setPolicy(ctx, drivePolicy{TrashRetentionDays: 365}); err != nil {
				t.Fatal(err)
			}
			trashOldItem(t, d, folder, 40)
			if err := os.WriteFile(filepath.Join(folder, ".cloudmount", "policy.json"), []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
			result, err := d.maintain(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if result.PurgedEntries != 0 {
				t.Fatal("a 40-day-old entry was purged on a policy that can't be read")
			}
			if result.PurgeSkipped == "" {
				t.Fatal("skipping a purge should be reported")
			}
		})
	}
}

func TestNoPolicyAtAllMeansTheDefault(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	trashOldItem(t, d, folder, defaultRetentionDays+5)
	result, err := d.maintain(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.PurgedEntries != 1 {
		t.Fatalf("an entry past the default should go, got %+v", result)
	}
}

func TestAPolicyOutOfRangeCantBeSaved(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	for _, days := range []int{0, -1, maxRetentionDays + 1} {
		if err := d.setPolicy(context.Background(), drivePolicy{TrashRetentionDays: days}); err == nil {
			t.Fatalf("%d days should be refused", days)
		}
	}
	for _, seconds := range []int64{0, -60, minRetentionSeconds - 1, maxRetentionDays*secondsPerDay + 1} {
		if err := d.setPolicy(context.Background(), policyLasting(seconds)); err == nil {
			t.Fatalf("%d seconds should be refused", seconds)
		}
	}
}

func TestNoPolicyAtAllMeansAWeek(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	policy, err := d.policy(ctx)
	if err != nil || policy.retention() != 7*24*time.Hour {
		t.Fatalf("policy %+v %v", policy, err)
	}

	id := trashAgedItem(t, d, folder, 6*24*time.Hour)
	if result, _ := d.maintain(ctx); result.PurgedEntries != 0 {
		t.Fatal("six days is inside a week")
	}
	age(t, filepath.Join(folder, ".cloudmount", "trash", id), 8*24*time.Hour)
	if result, _ := d.maintain(ctx); result.PurgedEntries != 1 {
		t.Fatalf("eight days is past a week, got %+v", result)
	}
}

func TestAShortRetentionMeansWhatItSays(t *testing.T) {
	for name, test := range map[string]struct {
		seconds    int64
		kept, gone time.Duration
	}{
		"a minute": {60, 30 * time.Second, 2 * time.Minute},
		"an hour":  {3_600, 50 * time.Minute, 70 * time.Minute},
		"a day":    {86_400, 23 * time.Hour, 25 * time.Hour},
	} {
		t.Run(name, func(t *testing.T) {
			folder := t.TempDir()
			d := openSFTP(t, startSFTP(t, folder))
			ctx := context.Background()
			if err := d.setPolicy(ctx, policyLasting(test.seconds)); err != nil {
				t.Fatal(err)
			}

			id := trashAgedItem(t, d, folder, test.kept)
			result, err := d.maintain(ctx)
			if err != nil || result.PurgedEntries != 0 {
				t.Fatalf("it went early: %+v %v", result, err)
			}
			if result.RetentionSeconds != test.seconds {
				t.Fatalf("the app was told %d", result.RetentionSeconds)
			}

			age(t, filepath.Join(folder, ".cloudmount", "trash", id), test.gone)
			if result, _ := d.maintain(ctx); result.PurgedEntries != 1 {
				t.Fatalf("it should have gone, got %+v", result)
			}
		})
	}
}

func TestAnEarlierVersionGoesWithAShortRetention(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	if err := d.setPolicy(ctx, policyLasting(60)); err != nil {
		t.Fatal(err)
	}
	var counter atomic.Int64
	first, err := d.save(ctx, writeLocal(t, []byte("first")), "file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.save(ctx, writeLocal(t, []byte("second")), "file.txt", first.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(ctx)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries %+v %v", entries, err)
	}

	age(t, filepath.Join(folder, ".cloudmount", "trash", entries[0].ID), 2*time.Minute)
	if result, _ := d.maintain(ctx); result.PurgedEntries != 1 {
		t.Fatalf("it should have gone, got %+v", result)
	}
	content, err := os.ReadFile(filepath.Join(folder, "file.txt"))
	if err != nil || string(content) != "second" {
		t.Fatalf("the file itself must stay: %q %v", content, err)
	}
}

// Another device may still be on an older build, which only reads the days and purges by them.
func TestAnOlderBuildNeverPurgesSoonerThanTheExactTime(t *testing.T) {
	for seconds, days := range map[int64]int{60: 1, 3_600: 1, 86_400: 1, 86_401: 2, 7 * 86_400: 7} {
		if got := policyLasting(seconds).TrashRetentionDays; got != days {
			t.Errorf("%d seconds gives %d days", seconds, got)
		}
	}

	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	if err := d.setPolicy(context.Background(), policyLasting(60)); err != nil {
		t.Fatal(err)
	}
	written, err := os.ReadFile(filepath.Join(folder, ".cloudmount", "policy.json"))
	if err != nil {
		t.Fatal(err)
	}
	var older struct {
		TrashRetentionDays int `json:"trashRetentionDays"`
	}
	if err := json.Unmarshal(written, &older); err != nil || older.TrashRetentionDays != 1 {
		t.Fatalf("an older build reads %+v from %s: %v", older, written, err)
	}
}

func TestAPolicyFromAnOlderBuildStillWorks(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	if err := d.setPolicy(ctx, drivePolicy{TrashRetentionDays: 7}); err != nil {
		t.Fatal(err)
	}
	policyPath := filepath.Join(folder, ".cloudmount", "policy.json")
	if err := os.WriteFile(policyPath, []byte(`{"trashRetentionDays":30}`), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := d.retentionInfo(ctx)
	if err != nil || info.TrashRetentionSeconds != 30*secondsPerDay {
		t.Fatalf("info %+v %v", info, err)
	}
}

func TestAPolicyIsPublishedInOneStep(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, folder string) {
		ctx := context.Background()
		for _, days := range []int{7, 30} {
			if err := d.setPolicy(ctx, drivePolicy{TrashRetentionDays: days}); err != nil {
				t.Fatal(err)
			}
		}
		policy, err := d.policy(ctx)
		if err != nil || policy.TrashRetentionDays != 30 {
			t.Fatalf("policy %+v %v", policy, err)
		}
		left, _ := os.ReadDir(filepath.Join(folder, ".cloudmount", "staging", d.deviceID))
		if len(left) != 0 {
			t.Fatalf("publishing left %d staged files", len(left))
		}
	})
}

func TestAPurgeWaitsForARestoreOfTheSameEntry(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	id := trashOldItem(t, d, folder, 40)
	ctx := context.Background()
	entry := trashFolder + "/" + id
	// The claim a restore holds, for as long as the purge is willing to wait.
	held, err := acquireClaim(ctx, d.server, entry)
	if err != nil {
		t.Fatal(err)
	}
	defer releaseClaim(d.server, held)
	short, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	if d.purgeEntry(short, entry, 24*time.Hour) {
		t.Fatal("a purge took an entry a restore was holding")
	}
	if _, err := d.server.statRaw(ctx, entry+"/item"); err != nil {
		t.Fatalf("the item should still be there: %v", err)
	}
}

// MARK: Vault markers (R05)

func editMarker(t *testing.T, server string, edit func(*vaultMarker), file string) {
	t.Helper()
	folder := filepath.Join(server, ".cloudmount", "vault")
	content, err := os.ReadFile(filepath.Join(folder, "1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var marker vaultMarker
	if err := json.Unmarshal(content, &marker); err != nil {
		t.Fatal(err)
	}
	edit(&marker)
	edited, _ := json.Marshal(marker)
	if err := os.WriteFile(filepath.Join(folder, file), edited, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestAnEditedMarkerWithTheOldCheckIsRefused(t *testing.T) {
	for name, edit := range map[string]func(*vaultMarker){
		"salt":    func(m *vaultMarker) { m.Salt = "dGFtcGVyZWQ=" },
		"options": func(m *vaultMarker) { m.Crypt.FilenameEncoding = "base64" },
		"state":   func(m *vaultMarker) { m.State = "retired" },
		"id":      func(m *vaultMarker) { m.VaultID = "someone-else" },
	} {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a, _, server := twoDevices(t)
			editMarker(t, server, edit, "1.json")
			if err := a.checkVault(ctx, true); err == nil {
				t.Error("an open drive accepted an edited marker")
			}
			if _, err := a.vaultDetails(ctx); err == nil {
				t.Error("a recovery kit would carry an edited marker")
			}
			if err := a.retireVault(ctx); err == nil {
				t.Error("retiring re-signed an edited marker")
			}
		})
	}
}

func TestAForgedHigherRevisionIsRefused(t *testing.T) {
	a, _, server := twoDevices(t)
	editMarker(t, server, func(m *vaultMarker) { m.Revision = 99 }, "99.json")
	if err := a.checkVault(context.Background(), true); err == nil {
		t.Fatal("a forged revision was accepted without being verified")
	}
}

func TestAProperlyRetiredVaultIsStillRecognised(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	if err := a.retireVault(ctx); err != nil {
		t.Fatal(err)
	}
	if err := b.checkVault(ctx, true); !errors.Is(err, errVaultRetired) {
		t.Fatalf("a signed retirement should be accepted and stop writes: %v", err)
	}
}

// MARK: Restored paths (R06)

func TestABadRestorePathIsRefused(t *testing.T) {
	for _, bad := range []string{
		"", "/etc/passwd", "../outside.txt", "a/../../outside.txt", "a//b", "./a", "a/.",
		".cloudmount/policy.json", "a/.cloudmount/b", ".cm-secret", "a/.cm-x/b",
		"a\x00b", `a\b`, strings.Repeat("n", maxServerNameBytes+1),
	} {
		if checkRestorePath(bad) == nil {
			t.Errorf("%q should be refused", bad)
		}
	}
	for _, good := range []string{"a.txt", "folder/a.txt", "año/ñu.txt", ".hidden", "a b/c d"} {
		if err := checkRestorePath(good); err != nil {
			t.Errorf("%q should be fine: %v", good, err)
		}
	}
}

func plantEntry(t *testing.T, root, originalPath string) {
	t.Helper()
	entry := filepath.Join(root, ".cloudmount", "trash", "evil")
	if err := os.MkdirAll(entry, 0o700); err != nil {
		t.Fatal(err)
	}
	meta, _ := json.Marshal(trashEntry{OriginalPath: originalPath, DeletedAt: 1, Device: "x"})
	if err := os.WriteFile(filepath.Join(entry, "meta"), meta, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(entry, "item"), []byte("planted"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestARestoreCantLeaveTheDrive(t *testing.T) {
	run := func(t *testing.T, open func(root string) *drive) {
		parent := t.TempDir()
		root := filepath.Join(parent, "root")
		if err := os.Mkdir(root, 0o700); err != nil {
			t.Fatal(err)
		}
		d := open(root)
		plantEntry(t, root, "../outside.txt")
		if _, err := d.restoreFromTrash(context.Background(), "evil"); !errors.Is(err, errDamagedEntry) {
			t.Fatalf("expected a damaged entry, got %v", err)
		}
		if _, err := os.Stat(filepath.Join(parent, "outside.txt")); err == nil {
			t.Fatal("restore wrote outside the drive's folder")
		}
		entries, err := d.trashEntries(context.Background())
		if err != nil || len(entries) != 1 || !entries[0].IsDamaged {
			t.Fatalf("the entry should show as damaged: %+v %v", entries, err)
		}
	}
	t.Run("WebDAV", func(t *testing.T) { run(t, func(root string) *drive { return plainDAV(t, root) }) })
	t.Run("SFTP", func(t *testing.T) { run(t, func(root string) *drive { return openSFTP(t, startSFTP(t, root)) }) })
}

func TestServerPathsCantClimbOutOfTheDrive(t *testing.T) {
	s := &sftpServer{root: "/data/drive"}
	for raw, want := range map[string]string{
		"file.txt":        "/data/drive/file.txt",
		"":                "/data/drive",
		"../outside.txt":  "/data/drive/outside.txt",
		"a/../../../etc":  "/data/drive/etc",
		"/absolute/place": "/data/drive/absolute/place",
	} {
		if got := s.full(raw); got != want {
			t.Errorf("full(%q) = %q, want %q", raw, got, want)
		}
	}
	home := &sftpServer{root: ""}
	if got := home.full("docs/a.txt"); got != "docs/a.txt" {
		t.Errorf("a home-relative path changed: %q", got)
	}
	if got := home.full(""); got != "." {
		t.Errorf("the home folder itself: %q", got)
	}

	dav := &davClient{endpoint: "https://example.com/data"}
	if got := dav.address("../outside.txt", false); got != "https://example.com/data/outside.txt" {
		t.Errorf("a WebDAV path climbed out: %q", got)
	}
}

// MARK: Replays (R07)

func TestAMoveReplayOnlyAdoptsItsOwnResult(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		ctx := context.Background()
		var counter atomic.Int64
		first, err := d.save(ctx, writeLocal(t, []byte("mine")), "a.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.save(ctx, writeLocal(t, []byte("somebody else's")), "b.txt", "", &counter); err != nil {
			t.Fatal(err)
		}
		if err := d.trash(ctx, "a.txt", first.Item.Version); err != nil {
			t.Fatal(err)
		}
		if moved, err := d.moveItem(ctx, "a.txt", "b.txt", first.Item.Version); err == nil {
			t.Fatalf("moving a vanished file adopted an unrelated one: %+v", moved)
		}
	})
}

func TestAMoveReplayFindsItsOwnResult(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		ctx := context.Background()
		var counter atomic.Int64
		first, err := d.save(ctx, writeLocal(t, []byte("mine")), "a.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}
		moved, err := d.moveItem(ctx, "a.txt", "b.txt", first.Item.Version)
		if err != nil {
			t.Fatal(err)
		}
		replayed, err := d.moveItem(ctx, "a.txt", "b.txt", first.Item.Version)
		if err != nil {
			t.Fatalf("the replay should find its own move: %v", err)
		}
		if replayed.Version != moved.Version {
			t.Fatalf("versions differ: %v %v", replayed.Version, moved.Version)
		}
	})
}

// MARK: Staging and committing (R08)

func TestAStageIsCommittedWhereverTheCallerSays(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, folder string) {
		ctx := context.Background()
		var counter atomic.Int64
		if err := d.mkdir(ctx, "old"); err != nil {
			t.Fatal(err)
		}
		first, err := d.save(ctx, writeLocal(t, []byte("before")), "old/file.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}
		source := writeLocal(t, []byte("after"))
		staged, err := d.stage(ctx, source, &counter)
		if err != nil {
			t.Fatal(err)
		}
		// The folder moves while the upload is running.
		if _, err := d.moveItem(ctx, "old", "new", ""); err != nil {
			t.Fatal(err)
		}
		if _, err := d.commitStage(ctx, staged.Staged, source, "new/file.txt", first.Item.Version, false, &counter); err != nil {
			t.Fatal(err)
		}
		content, _ := os.ReadFile(filepath.Join(folder, "new", "file.txt"))
		if string(content) != "after" {
			t.Fatalf("new/file.txt = %q", content)
		}
		if _, err := os.Stat(filepath.Join(folder, "old")); err == nil {
			t.Fatal("the old folder came back")
		}
	})
}

func TestADiscardedStageLeavesNothing(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		ctx := context.Background()
		var counter atomic.Int64
		staged, err := d.stage(ctx, writeLocal(t, []byte("never mind")), &counter)
		if err != nil {
			t.Fatal(err)
		}
		d.discardStage(staged.Staged)
		if _, err := d.server.statRaw(ctx, staged.Staged); !isNotFound(err) {
			t.Fatalf("the staged file should be gone: %v", err)
		}
	})
}

// MARK: Read-only and consent (R13, R14)

func TestAReadOnlyDriveRefusesEveryChange(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	d.readOnly = true
	drivesMu.Lock()
	drives["read-only-test"] = d
	drivesMu.Unlock()
	defer func() {
		drivesMu.Lock()
		delete(drives, "read-only-test")
		drivesMu.Unlock()
	}()
	arguments := []byte(`{"drive":"read-only-test","path":"a.txt"}`)
	var counter atomic.Int64
	for method := range changesTheDrive {
		if _, err := dispatch(context.Background(), method, arguments, &counter); !errors.Is(err, errReadOnly) {
			t.Errorf("%s: expected read-only, got %v", method, err)
		}
	}
	if _, err := dispatch(context.Background(), "list", []byte(`{"drive":"read-only-test"}`), &counter); err != nil {
		t.Errorf("reading should still work: %v", err)
	}
}

func TestEveryWritingMethodIsListedAsOne(t *testing.T) {
	for _, method := range []string{
		"trashRestore", "maintain", "setPolicy", "retireVault", "upload", "save", "stage", "commit",
		"mkdir", "move", "delete", "trash",
	} {
		if !changesTheDrive[method] {
			t.Errorf("%s writes to the server", method)
		}
	}
}

func TestPlainHTTPNeedsConsent(t *testing.T) {
	for _, address := range []string{"http://example.com/a", "HTTP://example.com/a", "HtTp://example.com/a"} {
		if err := checkTransport(address, false); !errors.Is(err, errInsecureRefused) {
			t.Errorf("%s: %v", address, err)
		}
		if err := checkTransport(address, true); err != nil {
			t.Errorf("%s with consent: %v", address, err)
		}
	}
	for _, address := range []string{"https://example.com/a", "HTTPS://example.com/a", "http://127.0.0.1:8080/a", "http://localhost/a", "http://[::1]/a"} {
		if err := checkTransport(address, false); err != nil {
			t.Errorf("%s: %v", address, err)
		}
	}
	for _, address := range []string{"ftp://example.com/a", "file:///etc", "example.com"} {
		if err := checkTransport(address, true); !errors.Is(err, errBadAddress) {
			t.Errorf("%s: %v", address, err)
		}
	}
}

// MARK: Hard limits (R01, R12)

func TestACancelledRequestLeavesItsWorkerAlone(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	secure := d.server.(*sftpServer)
	_, err := sftpRequest(context.Background(), secure, false, func(*sftp.Client) (int, error) {
		panic("a bug in a worker")
	})
	if err == nil || !strings.Contains(err.Error(), "the engine failed") {
		t.Fatalf("a worker's panic should become an error, got %v", err)
	}
}

// MARK: WebDAV replies (R17)

func multistatusServer(body string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusMultiStatus)
		fmt.Fprint(w, body)
	}))
}

func TestASignInPageIsntEvidenceAboutAnItem(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprint(w, "<html><body>Please sign in to this network</body></html>")
	}))
	defer server.Close()
	client := newDavClient(context.Background(), server.URL, "", "")
	_, err := client.statRaw(context.Background(), "file.txt")
	if got := classify(err).Kind; got != "unreachable" {
		t.Fatalf("a sign-in page should be a connection problem, got %q: %v", got, err)
	}
}

func TestAnEmptyOKStillMeansNotFound(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer server.Close()
	client := newDavClient(context.Background(), server.URL, "", "")
	if _, err := client.statRaw(context.Background(), "file.txt"); !isNotFound(err) {
		t.Fatalf("that's how Go's server reports a vanished item: %v", err)
	}
}

func TestAnEntryWithFailedPropertiesIsLeftOut(t *testing.T) {
	body := `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/data/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
<D:response><D:href>/data/secret-folder/</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat></D:response>
</D:multistatus>`
	server := multistatusServer(body)
	defer server.Close()
	client := newDavClient(context.Background(), server.URL+"/data", "", "")
	entries, err := client.listRaw(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("a forbidden folder was listed: %+v", entries)
	}
}

func TestAStatRefusesAnotherItemsDetails(t *testing.T) {
	body := `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/data/some-other-file.txt</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>5</D:getcontentlength><D:getetag>"x"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>`
	server := multistatusServer(body)
	defer server.Close()
	client := newDavClient(context.Background(), server.URL+"/data", "", "")
	entry, err := client.statRaw(context.Background(), "wanted.txt")
	if err == nil {
		t.Fatalf("a stat accepted a different file's details: %+v", entry)
	}
	if isNotFound(err) {
		t.Fatalf("a confusing reply isn't evidence the item is gone: %v", err)
	}
}

func TestAnUnreadableSizeIsntZero(t *testing.T) {
	for name, length := range map[string]string{
		"not a number": `<D:getcontentlength>huge</D:getcontentlength>`,
		"negative":     `<D:getcontentlength>-4</D:getcontentlength>`,
		"missing":      ``,
	} {
		t.Run(name, func(t *testing.T) {
			body := `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/data/file.txt</D:href><D:propstat><D:prop><D:resourcetype/>` + length + `<D:getetag>"x"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>`
			server := multistatusServer(body)
			defer server.Close()
			client := newDavClient(context.Background(), server.URL+"/data", "", "")
			entry, err := client.statRaw(context.Background(), "file.txt")
			if err == nil {
				t.Fatalf("an unreadable size was accepted: %+v", entry)
			}
			if isNotFound(err) {
				t.Fatalf("an unreadable item isn't a missing one: %v", err)
			}
		})
	}
}

func TestAListingThatDoesntAddUpIsRefused(t *testing.T) {
	body := `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/x/one.txt</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
<D:response><D:href>/y/deep/two.txt</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>`
	server := multistatusServer(body)
	defer server.Close()
	client := newDavClient(context.Background(), server.URL+"/data", "", "")
	if _, err := client.listRaw(context.Background(), ""); !errors.Is(err, errBadReply) {
		t.Fatalf("paths from nowhere should be refused: %v", err)
	}
}

func TestAProxyThatRewritesPathsStillLists(t *testing.T) {
	body := `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/internal/share/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
<D:response><D:href>/internal/share/one.txt</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>`
	server := multistatusServer(body)
	defer server.Close()
	client := newDavClient(context.Background(), server.URL+"/public", "", "")
	entries, err := client.listRaw(context.Background(), "")
	if err != nil || len(entries) != 1 || entries[0].Name != "one.txt" {
		t.Fatalf("entries %+v %v", entries, err)
	}
}

// MARK: Folder races

// apacheRace answers as Apache does to the loser of a folder race. Apache checks for the folder and
// then makes it, so two clients can both pass the check, and the loser's mkdir then fails as 403,
// not 405. This was found on the Storage Box: no local server does it.
type apacheRace struct {
	http.Handler
	folder string
}

func (a apacheRace) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if request.Method == "MKCOL" {
		if _, err := os.Stat(filepath.Join(a.folder, request.URL.Path)); err == nil {
			writer.WriteHeader(http.StatusForbidden)
			return
		}
	}
	a.Handler.ServeHTTP(writer, request)
}

func apacheRaceServer(t *testing.T, folder string) string {
	t.Helper()
	server := httptest.NewServer(apacheRace{
		&webdav.Handler{FileSystem: webdav.Dir(folder), LockSystem: webdav.NewMemLS()}, folder,
	})
	t.Cleanup(server.Close)
	return server.URL
}

func TestAFolderRaceLostWithA403IsNotARefusal(t *testing.T) {
	ctx := context.Background()
	client := newDavClient(ctx, apacheRaceServer(t, t.TempDir()), "", "")

	made, err := client.createExclusive(ctx, "claim")
	if err != nil || !made {
		t.Fatalf("first create = %v, %v", made, err)
	}
	made, err = client.createExclusive(ctx, "claim")
	if err != nil || made {
		t.Fatalf("the loser of the race = %v, %v", made, err)
	}
	if err := client.ensureFolder(ctx, "claim"); err != nil {
		t.Fatalf("ensuring a folder a peer just made: %v", err)
	}
}

func TestSimultaneousSavesOnAServerThatAnswersLikeApache(t *testing.T) {
	testServer = func(t *testing.T, folder string) driveConfig {
		return driveConfig{Kind: "webdav", URL: apacheRaceServer(t, folder)}
	}
	defer func() { testServer = nil }()
	TestSimultaneousSavesKeepBothVersions(t)
}

// A folder that really isn't allowed must still be reported, or a claim would wait out its whole
// time on a server that will never say yes.
func TestAServerThatRefusesAFolderIsStillARefusal(t *testing.T) {
	ctx := context.Background()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method == "MKCOL" {
			writer.WriteHeader(http.StatusForbidden)
			return
		}
		writer.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	client := newDavClient(ctx, server.URL, "", "")

	if _, err := client.createExclusive(ctx, "claim"); classify(err).Kind != "forbidden" {
		t.Fatalf("err = %v", err)
	}
	if err := client.ensureFolder(ctx, "claim"); classify(err).Kind != "forbidden" {
		t.Fatalf("err = %v", err)
	}
}

// MARK: Slow servers

func TestASlowDripFails(t *testing.T) {
	window := slowDripWindow
	slowDripWindow = 50 * time.Millisecond
	defer func() { slowDripWindow = window }()

	reader := steadyReader{r: dripReader{}, window: newRateWindow()}
	buffer := make([]byte, 16)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := reader.Read(buffer); err != nil {
			if !errors.Is(err, errTooSlow) {
				t.Fatalf("expected a slow server, got %v", err)
			}
			return
		}
	}
	t.Fatal("a trickle was allowed to go on")
}

// A folder that takes too long is that folder's problem. A server that's answering is still up,
// so this must not take the whole drive offline.
func TestAFolderThatRunsOutOfTimeIsNotAnOutage(t *testing.T) {
	limit := listingLimit
	listingLimit = 100 * time.Millisecond
	defer func() { listingLimit = limit }()

	a, _, _ := twoDevices(t)
	a.server = slowLister{a.server}
	_, err := a.serverList(context.Background(), "")
	if !errors.Is(err, errFolderTooSlow) {
		t.Fatalf("err = %v", err)
	}
	if got := classify(err).Kind; got != "tooSlow" {
		t.Fatalf("kind = %q", got)
	}
}

type slowLister struct{ rawServer }

func (slowLister) listRaw(ctx context.Context, _ string) ([]rawEntry, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

// A caller that gave up is not a slow folder.
func TestACancelledListingIsNotCalledSlow(t *testing.T) {
	a, _, _ := twoDevices(t)
	a.server = slowLister{a.server}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := a.serverList(ctx, ""); errors.Is(err, errFolderTooSlow) {
		t.Fatalf("err = %v", err)
	}
}

func digestServer(t *testing.T, challenges ...string) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		for _, challenge := range challenges {
			writer.Header().Add("WWW-Authenticate", challenge)
		}
		writer.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(server.Close)
	return server.URL
}

// Saying the password is wrong would send someone looking in the wrong place.
func TestADigestOnlyServerSaysSo(t *testing.T) {
	_, err := openDrive(context.Background(), driveConfig{
		ID: driveID(t), Kind: "webdav", URL: digestServer(t, `Digest realm="files", nonce="1"`),
		User: "someone", Password: "secret",
	})
	if !errors.Is(err, errDigestOnly) {
		t.Fatalf("err = %v", err)
	}
	if got := classify(err).Kind; got != "unsupportedServer" {
		t.Fatalf("kind = %q", got)
	}
}

func TestAServerOfferingBasicToo(t *testing.T) {
	_, err := openDrive(context.Background(), driveConfig{
		ID: driveID(t), Kind: "webdav",
		URL:  digestServer(t, `Digest realm="files", nonce="1"`, `Basic realm="files"`),
		User: "someone", Password: "wrong",
	})
	if errors.Is(err, errDigestOnly) {
		t.Fatalf("err = %v", err)
	}
	if got := classify(err).Kind; got != "unauthorized" {
		t.Fatalf("kind = %q, err = %v", got, err)
	}
}

type dripReader struct{}

func (dripReader) Read(p []byte) (int, error) {
	time.Sleep(2 * time.Millisecond)
	p[0] = 'x'
	return 1, nil
}

func TestAServerThatNeverAnswersIsGivenUpOn(t *testing.T) {
	limit := firstByteLimit
	firstByteLimit = 100 * time.Millisecond
	defer func() { firstByteLimit = limit }()

	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-release }))
	defer server.Close()
	defer close(release)
	client := newDavClient(context.Background(), server.URL, "", "")
	started := time.Now()
	_, err := client.statRaw(context.Background(), "file.txt")
	if !errors.Is(err, errTooSlow) {
		t.Fatalf("expected a slow server, got %v", err)
	}
	if got := classify(err).Kind; got != "unreachable" {
		t.Fatalf("a silent server is a connection problem, got %q", got)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("that took %v", elapsed)
	}
}

func TestAListingStopsWaitingWhenItsCallerDoes(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	for range listingsAtOnce {
		listingSlots <- struct{}{}
	}
	defer func() {
		for range listingsAtOnce {
			<-listingSlots
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := d.list(ctx, ""); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a queued listing should leave with its caller: %v", err)
	}
}

// MARK: Replaced versions (D1)

func TestAReplacedVersionCanBeRestored(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, folder string) {
		ctx := context.Background()
		var counter atomic.Int64
		first, err := d.save(ctx, writeLocal(t, []byte("first version")), "file.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := d.save(ctx, writeLocal(t, []byte("second version")), "file.txt", first.Item.Version, &counter); err != nil {
			t.Fatal(err)
		}
		entries, err := d.trashEntries(ctx)
		if err != nil || len(entries) != 1 || !entries[0].IsVersion || entries[0].OriginalPath != "file.txt" {
			t.Fatalf("the old version should be in the trash: %+v %v", entries, err)
		}
		restored, err := d.restoreFromTrash(ctx, entries[0].ID)
		if err != nil {
			t.Fatal(err)
		}
		content, _ := os.ReadFile(filepath.Join(folder, restored.Path))
		if string(content) != "first version" {
			t.Fatalf("restored %q as %s", content, restored.Path)
		}
		current, _ := os.ReadFile(filepath.Join(folder, "file.txt"))
		if string(current) != "second version" {
			t.Fatalf("restoring must not replace the current file, which holds %q", current)
		}
	})
}

// noCopyServer can't make a copy, like a server with no hard links or COPY.
type noCopyServer struct{ rawServer }

func (noCopyServer) keepCopy(context.Context, string, string, int64) error {
	return statusError(http.StatusNotImplemented)
}

func TestASaveCarriesOnIfItCantKeepTheOldVersion(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, folder string) {
		ctx := context.Background()
		var counter atomic.Int64
		first, err := d.save(ctx, writeLocal(t, []byte("first")), "file.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}
		real := d.server
		d.server = noCopyServer{real}
		_, err = d.save(ctx, writeLocal(t, []byte("second")), "file.txt", first.Item.Version, &counter)
		d.server = real
		if err != nil {
			t.Fatalf("keeping a copy is a second chance, never a reason to fail: %v", err)
		}
		content, _ := os.ReadFile(filepath.Join(folder, "file.txt"))
		if string(content) != "second" {
			t.Fatalf("file.txt holds %q", content)
		}
		left, _ := os.ReadDir(filepath.Join(folder, ".cloudmount", "trash"))
		if len(left) != 0 {
			t.Fatalf("a failed copy left %d entries behind", len(left))
		}
	})
}

func TestANewFileHasNothingToKeep(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	var counter atomic.Int64
	if _, err := d.save(context.Background(), writeLocal(t, []byte("new")), "file.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(context.Background())
	if err != nil || len(entries) != 0 {
		t.Fatalf("entries %+v %v", entries, err)
	}
}

func TestOldVersionsGoAfterAWeekWhateverTheRetention(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	if err := d.setPolicy(ctx, drivePolicy{TrashRetentionDays: 365}); err != nil {
		t.Fatal(err)
	}
	var counter atomic.Int64
	first, err := d.save(ctx, writeLocal(t, []byte("first")), "file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.save(ctx, writeLocal(t, []byte("second")), "file.txt", first.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(ctx)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries %+v %v", entries, err)
	}
	entry := filepath.Join(folder, ".cloudmount", "trash", entries[0].ID)

	aged := time.Now().Add(-6 * 24 * time.Hour)
	if err := os.Chtimes(entry, aged, aged); err != nil {
		t.Fatal(err)
	}
	if result, _ := d.maintain(ctx); result.PurgedEntries != 0 {
		t.Fatal("a six-day-old version went early")
	}
	aged = time.Now().Add(-8 * 24 * time.Hour)
	if err := os.Chtimes(entry, aged, aged); err != nil {
		t.Fatal(err)
	}
	if result, _ := d.maintain(ctx); result.PurgedEntries != 1 {
		t.Fatalf("an eight-day-old version should go, got %+v", result)
	}
}

func TestAHugeFileIsntCopiedOnWebDAV(t *testing.T) {
	client := &davClient{endpoint: "https://example.invalid"}
	if err := client.keepCopy(context.Background(), "a", "b", davCopyBytes+1); !errors.Is(err, errTooBigToKeep) {
		t.Fatalf("expected the size limit, got %v", err)
	}
}

// MARK: Third assessment

// savedWithTime saves content whose file has the given modified time, as a copy made with
// preserved times has.
func savedWithTime(t *testing.T, d *drive, content, name, base string, stamp time.Time) saveResult {
	t.Helper()
	var counter atomic.Int64
	source := writeLocal(t, []byte(content))
	if err := os.Chtimes(source, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	result, err := d.save(context.Background(), source, name, base, &counter)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

// SFTP has only size and whole-second time, so a repeated pair is a repeated version, and a device
// still holding the old one would overwrite whatever had replaced it.
func TestAStaleEditCantReturnThroughARepeatedVersion(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	stamp := time.Now().Add(-time.Hour).Truncate(time.Second)

	first := savedWithTime(t, d, "aaaa", "doc.txt", "", stamp)
	second := savedWithTime(t, d, "bbbb", "doc.txt", first.Item.Version, stamp)
	third := savedWithTime(t, d, "cccc", "doc.txt", second.Item.Version, stamp)
	if third.Item.Version == first.Item.Version {
		t.Fatal("a version came back after two saves")
	}

	stale := savedWithTime(t, d, "dddd", "doc.txt", first.Item.Version, stamp)
	if stale.ConflictPath == "" {
		t.Fatal("a stale edit replaced a newer version with no conflict")
	}
	content, err := os.ReadFile(filepath.Join(folder, "doc.txt"))
	if err != nil || string(content) != "cccc" {
		t.Fatalf("the server holds %q, %v", content, err)
	}
}

func TestOrdinarySavesInOneSecondNeverRepeatAVersion(t *testing.T) {
	ctx := context.Background()
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	var counter atomic.Int64
	seen := map[string]bool{}
	base := ""
	for run := range 6 {
		saved, err := d.save(ctx, writeLocal(t, []byte(fmt.Sprintf("v%03d", run))), "doc.txt", base, &counter)
		if err != nil {
			t.Fatal(err)
		}
		if seen[saved.Item.Version] {
			t.Fatalf("save %d repeated a version", run)
		}
		seen[saved.Item.Version] = true
		base = saved.Item.Version
	}
}

// An old document saved over a newer one must still look newer, whatever its own time says.
func TestAnOlderFileStillGetsANewerVersion(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	now := time.Now().Truncate(time.Second)
	first := savedWithTime(t, d, "first", "doc.txt", "", now)
	second := savedWithTime(t, d, "older", "doc.txt", first.Item.Version, now.Add(-24*time.Hour))
	if second.Item.ModifiedNS <= first.Item.ModifiedNS {
		t.Fatalf("time went backwards: %d after %d", second.Item.ModifiedNS, first.Item.ModifiedNS)
	}
}

func TestAnOpenPlainDriveRefusesANewVault(t *testing.T) {
	for _, kind := range []string{"webdav", "sftp"} {
		t.Run(kind, func(t *testing.T) {
			requireRclone(t)
			ctx := context.Background()
			folder := t.TempDir()
			config := driveConfig{Kind: "webdav"}
			if kind == "webdav" {
				config.URL = startWebDAV(t, folder)
			} else {
				config = startSFTP(t, folder)
			}
			plain := openSFTP(t, config)
			openEncrypted(t, driveID(t)+"-vault", config)
			var counter atomic.Int64

			if _, err := plain.save(ctx, writeLocal(t, []byte("secret")), "exposed.txt", "", &counter); !errors.Is(err, errVaultOnPlainDrive) {
				t.Errorf("a save: %v", err)
			}
			if err := plain.mkdir(ctx, "exposed"); !errors.Is(err, errVaultOnPlainDrive) {
				t.Errorf("a new folder: %v", err)
			}
			if err := plain.health(ctx); !errors.Is(err, errVaultOnPlainDrive) {
				t.Errorf("the health check: %v", err)
			}
			if _, err := os.Stat(filepath.Join(folder, "exposed.txt")); !os.IsNotExist(err) {
				t.Errorf("plain text reached the vault: %v", err)
			}
		})
	}
}

func TestAPlainDriveKeepsWorkingWithNoVault(t *testing.T) {
	ctx := context.Background()
	d := plainDAV(t, t.TempDir())
	var counter atomic.Int64
	if _, err := d.save(ctx, writeLocal(t, []byte("fine")), "doc.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	if err := d.health(ctx); err != nil {
		t.Fatal(err)
	}
}

// A broken reply says nothing about the item, and a false not-found would let a save replace it
// with no version check and no kept copy.
func TestABrokenReplyIsNeverNotFound(t *testing.T) {
	ctx := context.Background()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		connection, _, err := writer.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		fmt.Fprint(connection, "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n")
		connection.Close()
	}))
	defer server.Close()
	client := newDavClient(ctx, server.URL, "", "")
	if _, err := client.statRaw(ctx, "kept.txt"); classify(err).Kind == "notFound" {
		t.Fatalf("a broken reply became not-found: %v", err)
	}
}

func multistatusFor(href string) http.HandlerFunc {
	return func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusMultiStatus)
		fmt.Fprintf(writer, `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response>
<D:href>%s</D:href><D:propstat><D:prop><D:getcontentlength>7</D:getcontentlength>
<D:getetag>"tag"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>`, href)
	}
}

func TestAStatMustDescribeTheItemAskedAbout(t *testing.T) {
	ctx := context.Background()
	server := httptest.NewServer(multistatusFor("/somewhere-else/kept.txt"))
	defer server.Close()
	client := newDavClient(ctx, server.URL+"/root", "", "")
	if entry, err := client.statRaw(ctx, "kept.txt"); err == nil {
		t.Fatalf("a stat took another folder's item: %+v", entry)
	}
}

// A proxy can show a server under a longer or shorter path, and that's still the same item.
func TestAStatThroughAProxyStillWorks(t *testing.T) {
	ctx := context.Background()
	for address, href := range map[string]string{
		"/dav/root": "/root/kept.txt",
		"/root":     "/dav/root/kept.txt",
	} {
		server := httptest.NewServer(multistatusFor(href))
		client := newDavClient(ctx, server.URL+address, "", "")
		if _, err := client.statRaw(ctx, "kept.txt"); err != nil {
			t.Errorf("%s answered as %s: %v", address, href, err)
		}
		server.Close()
	}
}

// cutReads lists files at their true size, but serves less of them, with a matching length.
func cutReads(folder string, keep func(content []byte) []byte, isCutting *atomic.Bool) http.Handler {
	files := &webdav.Handler{FileSystem: webdav.Dir(folder), LockSystem: webdav.NewMemLS()}
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		isFile := request.Method == http.MethodGet && !strings.Contains(request.URL.Path, ".cloudmount")
		if isCutting.Load() && isFile {
			if content, err := os.ReadFile(filepath.Join(folder, request.URL.Path)); err == nil {
				short := keep(content)
				writer.Header().Set("Content-Length", fmt.Sprint(len(short)))
				writer.WriteHeader(http.StatusOK)
				_, _ = writer.Write(short)
				return
			}
		}
		files.ServeHTTP(writer, request)
	})
}

func TestAShortFileIsRefused(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	if err := os.WriteFile(filepath.Join(folder, "report.bin"), make([]byte, 200_000), 0o600); err != nil {
		t.Fatal(err)
	}
	var isCutting atomic.Bool
	isCutting.Store(true)
	server := httptest.NewServer(cutReads(folder, func(content []byte) []byte { return content[:len(content)/2] }, &isCutting))
	defer server.Close()
	d := openSFTP(t, driveConfig{Kind: "webdav", URL: server.URL})
	var counter atomic.Int64
	destination := filepath.Join(t.TempDir(), "out")
	if err := d.download(ctx, "report.bin", destination, &counter, ""); !errors.Is(err, errShortFile) {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(destination); !os.IsNotExist(err) {
		t.Fatalf("a short file was left behind: %v", err)
	}
}

// Each chunk authenticates on its own, so a cut between chunks leaves only valid data.
func TestAnEncryptedFileCutBetweenChunksIsRefused(t *testing.T) {
	requireRclone(t)
	ctx := context.Background()
	folder := t.TempDir()
	var isCutting atomic.Bool
	const header, block = 32, 65536 + 16
	server := httptest.NewServer(cutReads(folder, func(content []byte) []byte { return content[:header+block] }, &isCutting))
	defer server.Close()
	d := openEncrypted(t, driveID(t), driveConfig{Kind: "webdav", URL: server.URL, DeviceID: "device-a"})
	var counter atomic.Int64
	if _, err := d.save(ctx, writeLocal(t, make([]byte, 260_000)), "report.bin", "", &counter); err != nil {
		t.Fatal(err)
	}
	isCutting.Store(true)
	if err := d.download(ctx, "report.bin", filepath.Join(t.TempDir(), "out"), &counter, ""); !errors.Is(err, errShortFile) {
		t.Fatalf("err = %v", err)
	}
}
