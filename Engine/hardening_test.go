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
	"sync"
	"sync/atomic"
	"testing"
	"time"

	rcloneconfig "github.com/rclone/rclone/fs/config"
)

func init() {
	for name, test := range map[string]func(*testing.T){
		"NoVersionNoOverwrite":       TestAnExistingFileWithNoVersionIsNeverOverwritten,
		"RetiredVault":               TestAnOpenDriveNoticesARetiredVault,
		"ReplacedVault":              TestAnOpenDriveNoticesAReplacedVault,
		"VaultOnPlain":               TestAVaultNeverOpensAsAPlainDrive,
		"NameTooLong":                TestANameTooLongToEncryptIsRefusedClearly,
		"FormerOwner":                TestAFormerOwnerCantCommitAfterATakeover,
		"ExpiredRelease":             TestAnExpiredHolderNeverReleasesASuccessor,
		"SlowHolder":                 TestAHolderPastTheLimitGivesUp,
		"FreshClaimStays":            TestAFreshClaimIsNeverTakenOver,
		"MoveToItself":               TestMovingAnItemToItselfDoesntWaitOnItsOwnClaim,
		"SaveWaitsForFolder":         TestASaveStandsAsideForAFolderOperation,
		"FolderWaitsForSave":         TestAFolderMoveWaitsForALiveSave,
		"FolderIgnoresDeadClaim":     TestAFolderMoveIgnoresADeadSave,
		"ChildSaveAgainstMove":       TestAChildSaveAgainstAFolderMoveLosesNothing,
		"ChildSaveAgainstTrash":      TestAChildSaveAgainstAFolderTrashLosesNothing,
		"TwoTakeovers":               TestTwoDevicesTakingOverLeaveOneOwner,
		"NoClaimLeftByFolderMove":    TestAFolderMoveLeavesNoClaimsBehind,
		"NewFileWithBaseOnTakenName": TestANewFileNeverReplacesAnExistingOne,
		"RestoreFile":                TestADeletedFileCanBeRestored,
		"RestoreOverTakenName":       TestARestoreNeverReplacesAnything,
		"RestoreFolder":              TestADeletedFolderComesBackWhole,
		"PurgeOld":                   TestMaintenancePurgesOnlyWhatsPastRetention,
		"SweepStaging":               TestMaintenanceSweepsAbandonedStagingFiles,
		"Policy":                     TestRetentionIsSharedByDevices,
		"Retire":                     TestRetiringAVaultStopsEveryDevice,
		"Details":                    TestVaultDetailsReachTheFilesWithPlainRclone,
	} {
		commitTests[name] = test
	}
}

// noVersions is a server that reports no ETags, as some WebDAV servers do.
type noVersions struct {
	rawServer
}

func (s noVersions) statRaw(ctx context.Context, rawPath string) (rawEntry, error) {
	entry, err := s.rawServer.statRaw(ctx, rawPath)
	entry.ETag = ""
	return entry, err
}

func TestConcurrentClosesDontPanic(t *testing.T) {
	var group sync.WaitGroup
	for range 32 {
		group.Add(1)
		go func() {
			defer group.Done()
			for range 5000 {
				runCall(0, "close", []byte(`{"drive":"none"}`))
			}
		}()
	}
	group.Wait()
}

func TestAFailedOpenLeavesNoSecretsBehind(t *testing.T) {
	folder := t.TempDir()
	config := startSFTP(t, folder)
	id := driveID(t)
	openEncrypted(t, id+"-first", config)

	wrong := config
	wrong.ID = id + "-wrong"
	wrong.Encrypted = true
	wrong.VaultPassword = "not the password"
	if _, err := openDrive(context.Background(), wrong); !errors.Is(err, errWrongPassword) {
		t.Fatalf("err = %v", err)
	}
	if rcloneconfig.LoadedData().HasSection("ca-" + wrong.ID) {
		t.Error("a failed open left its configuration behind")
	}
}

func TestClosingAFailedDriveTwiceIsHarmless(t *testing.T) {
	closeDrive("never-opened")
	closeDrive("never-opened")
}

func TestAPanicBecomesAnError(t *testing.T) {
	_, err := guarded(func() (any, error) { panic("something broke") })
	if err == nil || !strings.Contains(err.Error(), "something broke") {
		t.Fatalf("err = %v", err)
	}
}

func TestVersionIDsHaveAFixedSize(t *testing.T) {
	short, long := versionID(`"a"`), versionID(strings.Repeat("x", 5000))
	if len(short) != 64 || len(long) != 64 {
		t.Errorf("lengths = %d, %d", len(short), len(long))
	}
	if versionID("") != "" {
		t.Error("no evidence must give an empty ID")
	}
}

func TestAnExistingFileWithNoVersionIsNeverOverwritten(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	var counter atomic.Int64
	base, err := a.save(ctx, writeLocal(t, []byte("first")), "file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	a.server = noVersions{a.server}

	for _, claimed := range []string{"", base.Item.Version} {
		result, err := a.save(ctx, writeLocal(t, []byte("second")), "file.txt", claimed, &counter)
		if err != nil {
			t.Fatal(err)
		}
		if result.ConflictPath == "" {
			t.Fatalf("base %q overwrote a file with no version", claimed)
		}
	}
	if got := read(t, a, "file.txt"); got != "first" {
		t.Errorf("content = %q", got)
	}
}

func TestANewFileNeverReplacesAnExistingOne(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	if _, err := a.save(ctx, writeLocal(t, []byte("from A")), "name.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	result, err := b.save(ctx, writeLocal(t, []byte("from B")), "name.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictPath == "" {
		t.Fatal("no conflict copy")
	}
	if got := read(t, a, "name.txt"); got != "from A" {
		t.Errorf("content = %q", got)
	}
}

func addMarkerRevision(t *testing.T, d *drive, change func(*vaultMarker)) {
	t.Helper()
	ctx := context.Background()
	marker, err := loadVaultMarker(ctx, d.plain)
	if err != nil || marker == nil {
		t.Fatalf("marker = %v, %v", marker, err)
	}
	next := *marker
	next.Revision++
	change(&next)
	if err := next.seal(interopPassword); err != nil {
		t.Fatal(err)
	}
	if err := writeVaultMarker(ctx, d.plain, next); err != nil {
		t.Fatal(err)
	}
	d.vault.checked = time.Time{}
}

func TestAnOpenDriveNoticesARetiredVault(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	var counter atomic.Int64
	if _, err := a.save(ctx, writeLocal(t, []byte("before")), "file.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	addMarkerRevision(t, a, func(marker *vaultMarker) { marker.State = "retired" })

	_, err := a.save(ctx, writeLocal(t, []byte("after")), "other.txt", "", &counter)
	if !errors.Is(err, errVaultRetired) {
		t.Fatalf("err = %v", err)
	}
	if err := a.health(ctx); !errors.Is(err, errVaultRetired) {
		t.Fatalf("health = %v", err)
	}
}

// Once a device has seen a vault retired, a server restored from before that is a rollback. If
// the retired revision were forgotten, the vault would look fine again and writes would resume.
func TestARetiredRevisionStaysPinned(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	addMarkerRevision(t, a, func(marker *vaultMarker) { marker.State = "retired" })
	if err := a.health(ctx); !errors.Is(err, errVaultRetired) {
		t.Fatalf("health = %v", err)
	}

	if err := os.Remove(filepath.Join(server, vaultFolder, "2.json")); err != nil {
		t.Fatal(err)
	}
	a.vault.checked = time.Time{}
	if err := a.health(ctx); !errors.Is(err, errVaultRollback) {
		t.Fatalf("after the retired revision vanished, health = %v", err)
	}
}

// The check is skipped if it ran a moment ago, and that mustn't let a write past a retired vault.
func TestARecentCheckStillRefusesARetiredVault(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	addMarkerRevision(t, a, func(marker *vaultMarker) { marker.State = "retired" })
	if err := a.health(ctx); !errors.Is(err, errVaultRetired) {
		t.Fatalf("health = %v", err)
	}
	if err := a.checkVault(ctx, false); !errors.Is(err, errVaultRetired) {
		t.Fatalf("a cached check = %v", err)
	}
}

func TestTheAppCanPinTheHighestRevisionSeen(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	if got := a.vaultRevision(); got != 1 {
		t.Fatalf("revision = %d", got)
	}
	addMarkerRevision(t, a, func(marker *vaultMarker) { marker.State = "retired" })
	_ = a.health(ctx)
	if got := a.vaultRevision(); got != 2 {
		t.Fatalf("revision after retiring = %d", got)
	}
}

func TestAnOpenDriveNoticesAReplacedVault(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	addMarkerRevision(t, a, func(marker *vaultMarker) { marker.VaultID = "another-vault" })

	if err := a.health(ctx); !errors.Is(err, errVaultMismatch) {
		t.Fatalf("health = %v", err)
	}
}

func TestAVaultNeverOpensAsAPlainDrive(t *testing.T) {
	folder := t.TempDir()
	base := driveConfig{Kind: "webdav"}
	if testServer != nil {
		base = testServer(t, folder)
	} else {
		base.URL = startWebDAV(t, folder)
	}
	id := driveID(t)
	openEncrypted(t, id+"-encrypted", base)

	plain := base
	plain.ID = id + "-plain"
	_, err := openDrive(context.Background(), plain)
	if !errors.Is(err, errVaultOnPlainDrive) {
		t.Fatalf("err = %v", err)
	}
	if kind := classify(err).Kind; kind != "vaultEncrypted" {
		t.Errorf("kind = %q", kind)
	}
}

func TestANameTooLongToEncryptIsRefusedClearly(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	var counter atomic.Int64
	name := strings.Repeat("n", 200) + ".txt"

	_, err := a.save(ctx, writeLocal(t, []byte("x")), name, "", &counter)
	if !errors.Is(err, errNameTooLong) {
		t.Fatalf("err = %v", err)
	}
	if kind := classify(err).Kind; kind != "nameTooLong" {
		t.Errorf("kind = %q", kind)
	}
	if err := a.mkdir(ctx, name); !errors.Is(err, errNameTooLong) {
		t.Errorf("mkdir err = %v", err)
	}
	if _, err := a.save(ctx, writeLocal(t, []byte("x")), strings.Repeat("n", 120)+".txt", "", &counter); err != nil {
		t.Errorf("a long but valid name failed: %v", err)
	}
}

func TestAFormerOwnerCantCommitAfterATakeover(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	held, err := acquireClaim(ctx, a.server, "file")
	if err != nil {
		t.Fatal(err)
	}
	if err := held.stillOwned(ctx, a.server); err != nil {
		t.Fatalf("a fresh claim isn't owned: %v", err)
	}

	// Another device takes the claim over and makes its own at the same path.
	if err := b.server.moveRaw(ctx, held.path, claimsFolder+"/stale-test", true, false); err != nil {
		t.Fatal(err)
	}
	successor, err := acquireClaim(ctx, b.server, "file")
	if err != nil {
		t.Fatal(err)
	}
	defer releaseClaim(b.server, successor)

	if err := held.stillOwned(ctx, a.server); !errors.Is(err, errClaimLost) {
		t.Fatalf("former owner: %v", err)
	}
	if err := successor.stillOwned(ctx, b.server); err != nil {
		t.Fatalf("successor: %v", err)
	}
}

func TestAnExpiredHolderNeverReleasesASuccessor(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	former, err := acquireClaim(ctx, a.server, "file")
	if err != nil {
		t.Fatal(err)
	}
	if err := b.server.moveRaw(ctx, former.path, claimsFolder+"/stale-test", true, false); err != nil {
		t.Fatal(err)
	}
	successor, err := acquireClaim(ctx, b.server, "file")
	if err != nil {
		t.Fatal(err)
	}
	defer releaseClaim(b.server, successor)

	// The former owner wakes after its hold limit and tries to clean up.
	former.taken = time.Now().Add(-2 * claimHoldLimit)
	releaseClaim(a.server, former)

	if err := successor.stillOwned(ctx, b.server); err != nil {
		t.Fatalf("the successor lost its claim: %v", err)
	}
}

func TestAHolderPastTheLimitGivesUp(t *testing.T) {
	ctx := context.Background()
	a, _, _ := twoDevices(t)
	held, err := acquireClaim(ctx, a.server, "file")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		held.taken, held.wallTaken = time.Now(), time.Now()
		releaseClaim(a.server, held)
	}()

	// The monotonic clock stops during sleep, so the wall clock alone must be enough.
	held.wallTaken = time.Now().Add(-2 * claimHoldLimit)
	if err := held.stillOwned(ctx, a.server); !errors.Is(err, errClaimLost) {
		t.Fatalf("err = %v", err)
	}
}

func TestAFreshClaimIsNeverTakenOver(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	held, err := acquireClaim(ctx, a.server, "file")
	if err != nil {
		t.Fatal(err)
	}
	defer releaseClaim(a.server, held)

	takeOverIfStale(ctx, b.server, held.path)

	if err := held.stillOwned(ctx, a.server); err != nil {
		t.Fatalf("a live claim was taken: %v", err)
	}
}

func TestTwoDevicesTakingOverLeaveOneOwner(t *testing.T) {
	ctx := context.Background()
	a, b, server := twoDevices(t)
	for run := range 10 {
		claim := claimPath("abandoned")
		folder := filepath.Join(server, claim)
		if err := os.MkdirAll(folder, 0o700); err != nil {
			t.Fatal(err)
		}
		old := time.Now().Add(-2 * claimStaleAfter)
		if err := os.Chtimes(folder, old, old); err != nil {
			t.Fatal(err)
		}

		var group sync.WaitGroup
		for _, d := range []*drive{a, b} {
			group.Add(1)
			go func() {
				defer group.Done()
				takeOverIfStale(ctx, d.server, claim)
			}()
		}
		group.Wait()

		if _, err := os.Stat(folder); !os.IsNotExist(err) {
			t.Fatalf("run %d: the abandoned claim survived: %v", run, err)
		}
	}
}

func TestMovingAnItemToItselfDoesntWaitOnItsOwnClaim(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a, _, _ := twoDevices(t)
	var counter atomic.Int64
	if _, err := a.save(ctx, writeLocal(t, []byte("x")), "file.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	if _, err := a.moveItem(ctx, "file.txt", "file.txt", ""); err != nil {
		t.Fatalf("err = %v", err)
	}
}

func TestASaveStandsAsideForAFolderOperation(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	held, err := acquireClaimFolder(ctx, b.server, structureClaim)
	if err != nil {
		t.Fatal(err)
	}

	short, cancel := context.WithTimeout(ctx, 700*time.Millisecond)
	defer cancel()
	if _, err := a.save(short, writeLocal(t, []byte("x")), "file.txt", "", &counter); err == nil {
		t.Fatal("a save went ahead during a folder operation")
	}

	releaseClaim(b.server, held)
	if _, err := a.save(ctx, writeLocal(t, []byte("x")), "file.txt", "", &counter); err != nil {
		t.Fatalf("after the folder operation: %v", err)
	}
}

func TestAFolderMoveWaitsForALiveSave(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	if err := a.mkdir(ctx, "folder"); err != nil {
		t.Fatal(err)
	}
	held, err := acquireClaim(ctx, b.server, "folder/file")
	if err != nil {
		t.Fatal(err)
	}

	short, cancel := context.WithTimeout(ctx, 700*time.Millisecond)
	defer cancel()
	if _, err := a.moveItem(short, "folder", "renamed", ""); err == nil {
		t.Fatal("a folder moved during a save")
	}

	releaseClaim(b.server, held)
	if _, err := a.moveItem(ctx, "folder", "renamed", ""); err != nil {
		t.Fatalf("after the save: %v", err)
	}
}

func TestAFolderMoveIgnoresADeadSave(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	a, _, server := twoDevices(t)
	if err := a.mkdir(ctx, "folder"); err != nil {
		t.Fatal(err)
	}
	dead := filepath.Join(server, claimPath("folder/file"))
	if err := os.MkdirAll(dead, 0o700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-2 * claimLiveFor)
	if err := os.Chtimes(dead, old, old); err != nil {
		t.Fatal(err)
	}

	if _, err := a.moveItem(ctx, "folder", "renamed", ""); err != nil {
		t.Fatalf("err = %v", err)
	}
}

func TestAFolderMoveLeavesNoClaimsBehind(t *testing.T) {
	ctx := context.Background()
	a, _, server := twoDevices(t)
	if err := a.mkdir(ctx, "folder"); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(server, claimsFolder), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := a.moveItem(ctx, "folder", "renamed", ""); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(filepath.Join(server, claimsFolder))
	if len(entries) != 0 {
		t.Errorf("claims left: %v", entries)
	}
}

// everything returns the content of every file on a drive, wherever it ended up.
func everything(t *testing.T, d *drive, dir string) []string {
	t.Helper()
	items, err := d.list(context.Background(), dir)
	if err != nil {
		t.Fatalf("list %q: %v", dir, err)
	}
	var contents []string
	for _, item := range items {
		if item.IsDirectory {
			contents = append(contents, everything(t, d, item.Path)...)
		} else {
			contents = append(contents, read(t, d, item.Path))
		}
	}
	return contents
}

// saveAsMacOSDoes tries again when a claim stays busy. That error means nothing was saved and the
// bytes are still macOS's, which sends them again. On a slow server a folder move can outlast the
// time a save waits for it.
func saveAsMacOSDoes(ctx context.Context, d *drive, source, name, base string, counter *atomic.Int64) error {
	var err error
	for range 5 {
		if _, err = d.save(ctx, source, name, base, counter); err == nil || classify(err).Kind != "locked" {
			return err
		}
	}
	return err
}

// Each run saves its own content. The drive keeps what earlier runs saved, so if they all saved
// the same words, only the first run would prove anything.
func TestAChildSaveAgainstAFolderMoveLosesNothing(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	for run := range 8 {
		folder, moved := fmt.Sprintf("run-%d", run), fmt.Sprintf("moved-%d", run)
		saved := fmt.Sprintf("new %d", run)
		base, err := a.save(ctx, writeLocal(t, []byte("old")), folder+"/file.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}

		var group sync.WaitGroup
		group.Add(2)
		go func() {
			defer group.Done()
			if err := saveAsMacOSDoes(ctx, a, writeLocal(t, []byte(saved)), folder+"/file.txt", base.Item.Version, &counter); err != nil {
				t.Errorf("save: %v", err)
			}
		}()
		go func() {
			defer group.Done()
			if _, err := b.moveItem(ctx, folder, moved, ""); err != nil {
				t.Errorf("move: %v", err)
			}
		}()
		group.Wait()

		if !slices.Contains(everything(t, a, ""), saved) {
			t.Fatalf("run %d lost the save", run)
		}
	}
}

func TestAChildSaveAgainstAFolderTrashLosesNothing(t *testing.T) {
	ctx := context.Background()
	a, b, _ := twoDevices(t)
	var counter atomic.Int64
	for run := range 6 {
		folder := fmt.Sprintf("trashed-%d", run)
		saved := fmt.Sprintf("new %d", run)
		base, err := a.save(ctx, writeLocal(t, []byte("old")), folder+"/file.txt", "", &counter)
		if err != nil {
			t.Fatal(err)
		}

		var group sync.WaitGroup
		group.Add(2)
		go func() {
			defer group.Done()
			if err := saveAsMacOSDoes(ctx, a, writeLocal(t, []byte(saved)), folder+"/file.txt", base.Item.Version, &counter); err != nil {
				t.Errorf("save: %v", err)
			}
		}()
		go func() {
			defer group.Done()
			if err := b.trash(ctx, folder, ""); err != nil {
				t.Errorf("trash: %v", err)
			}
		}()
		group.Wait()

		// The new version is on the drive, or it went to the trash inside the folder, so
		// restoring the folder has to bring it back. Counting trash entries proves nothing,
		// because every save adds one for the version it replaced.
		if !slices.Contains(everything(t, a, ""), saved) {
			entries, err := a.trashEntries(ctx)
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if entry.IsDirectory && entry.OriginalPath == folder {
					if _, err := a.restoreFromTrash(ctx, entry.ID); err != nil {
						t.Fatalf("run %d: restoring: %v", run, err)
					}
				}
			}
		}
		if !slices.Contains(everything(t, a, ""), saved) {
			t.Fatalf("run %d lost the save", run)
		}
	}
}
