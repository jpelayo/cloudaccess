// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"errors"
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// A drive works in one of three modes, chosen by a person.
//
//   - Safe is the commit layer the rest of this package describes: claims, staging and trash in
//     the control folder, so no save overwrites a peer's and every delete can be undone.
//   - Unsafe writes nothing but a person's files, for servers that must stay clean. On SFTP only,
//     because its posix-rename replaces a file in one step: WebDAV servers delete the target
//     first. Saves still check macOS's base version, still keep both versions on a conflict, and
//     still land in one step. What's given up is the claim, so two devices saving one file at
//     the same moment can lose one save, and the trash, so deletes and replaced versions are
//     gone for good.
//   - Read-only writes nothing at all.
//
// An encrypted drive keeps its vault marker in every mode: the key needs its salt.

const (
	modeSafe     = "safe"
	modeUnsafe   = "unsafe"
	modeReadOnly = "readOnly"

	// reservedPrefix marks the engine's own names among a person's files. They're never listed,
	// and the app refuses them as names.
	reservedPrefix = ".cm-"
	uploadSuffix   = ".part"

	// busyStagingWindow is how recently a staging file must have changed for a Safe device to
	// count as saving, so the control folder isn't cleared under it.
	busyStagingWindow = 10 * time.Minute
)

var (
	errUnsafeNeedsSFTP        = errors.New("only SFTP drives can work without the control folder")
	errUnsafeKeepsNoTrash     = errors.New("in Unsafe mode this drive keeps no deleted files")
	errSafeNeedsControlFolder = errors.New("a drive in Safe mode needs its control folder")
	errControlFolderBusy      = errors.New("another device is saving to this drive, so its folder was kept")
)

// needsTrash lists the calls that only make sense with the control folder's trash and policy.
var needsTrash = map[string]bool{"setPolicy": true, "trashRestore": true, "trashPurge": true, "retireVault": true}

// driveMode reads a drive's mode. A drive the app opens read-only, because the server is, stays
// read-only whatever its mode.
func driveMode(c driveConfig) (readOnly, unsafe bool, err error) {
	switch c.Mode {
	case "", modeSafe:
		return c.ReadOnly, false, nil
	case modeReadOnly:
		return true, false, nil
	case modeUnsafe:
		if c.Kind != "sftp" {
			return false, false, errUnsafeNeedsSFTP
		}
		return c.ReadOnly, !c.ReadOnly, nil
	}
	return false, false, fmt.Errorf("unknown drive mode %q", c.Mode)
}

// isReservedName says whether a name in a listing is the engine's own.
func isReservedName(name string) bool {
	return name == controlFolder || strings.HasPrefix(name, reservedPrefix)
}

// unsafeUploadName is where an Unsafe save uploads before its final move: a hidden file in the
// drive's root, on the same server, so the move into place is a rename. It carries the device
// and the time the upload began, so leftovers from a crash can be told apart and aged.
func (d *drive) unsafeUploadName() string {
	return fmt.Sprintf("%s%s-%d-%s%s", reservedPrefix, d.deviceID, time.Now().Unix(), uuid.NewString(), uploadSuffix)
}

// ownUpload reads back when one of this device's Unsafe uploads began.
func ownUpload(name, deviceID string) (time.Time, bool) {
	rest, own := strings.CutPrefix(name, reservedPrefix+deviceID+"-")
	if !own || !strings.HasSuffix(rest, uploadSuffix) {
		return time.Time{}, false
	}
	stamp, _, found := strings.Cut(rest, "-")
	if !found {
		return time.Time{}, false
	}
	seconds, err := strconv.ParseInt(stamp, 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	return time.Unix(seconds, 0), true
}

// withoutClaims runs an Unsafe change. The vault is still checked, so nothing is written beside
// a vault that changed or went away.
func (d *drive) withoutClaims(ctx context.Context, body func(stillHeld func() error) error) error {
	if err := d.checkVault(ctx, false); err != nil {
		return err
	}
	return body(func() error { return nil })
}

// removeForGood is an Unsafe delete: there's no trash to move it to.
func (d *drive) removeForGood(ctx context.Context, raw string, folder bool) error {
	if folder {
		return d.server.removeAll(ctx, raw)
	}
	return d.server.remove(ctx, raw, false)
}

// sweepUnsafeUploads is maintenance in Unsafe mode. It removes this device's own uploads left by a
// crash, once none could still be running, and only counts other devices': their uploads may be
// live, and this device can't know.
func (d *drive) sweepUnsafeUploads(ctx context.Context) (maintenanceResult, error) {
	var result maintenanceResult
	entries, err := d.server.listRaw(ctx, "")
	if err != nil {
		return result, err
	}
	for _, entry := range entries {
		if entry.IsDirectory || !strings.HasPrefix(entry.Name, reservedPrefix) || !strings.HasSuffix(entry.Name, uploadSuffix) {
			continue
		}
		started, own := ownUpload(entry.Name, d.deviceID)
		if !own {
			result.OtherDevicesUploads++
			continue
		}
		if _, running := d.staged.Load(entry.Name); running || time.Since(started) <= ownStagingLifetime {
			continue
		}
		if d.server.remove(ctx, entry.Name, false) == nil {
			result.SweptFiles++
		}
	}
	return result, nil
}

// controlFolderReport says what the control folder holds, so a person can decide whether to
// remove it.
type controlFolderReport struct {
	Exists   bool `json:"exists"`
	HasVault bool `json:"hasVault"`
	// TrashItems is how many deleted files and kept versions would be gone for good.
	TrashItems int `json:"trashItems"`
	// SafeDevices is how many other devices have uploaded here in Safe mode. Those will make
	// the folder again.
	SafeDevices int `json:"safeDevices"`
	// Busy says a Safe device looks to be saving now, by this device's clock. The clean-up
	// checks again by the server's.
	Busy    bool `json:"busy"`
	Removed bool `json:"removed"`
	// OtherEntries is what's there besides the vault: trash, uploads, claims and settings.
	OtherEntries int `json:"otherEntries"`
}

func (d *drive) controlFolderContents(ctx context.Context) (controlFolderReport, error) {
	var report controlFolderReport
	if d.server == nil {
		return report, nil
	}
	entries, err := d.server.listRaw(ctx, controlFolder)
	if isNotFound(err) {
		return report, nil
	}
	if err != nil {
		return report, err
	}
	report.Exists = true
	for _, entry := range entries {
		if entry.Name == path.Base(vaultFolder) {
			report.HasVault = true
		} else {
			report.OtherEntries++
		}
	}
	trash, err := d.server.listRaw(ctx, trashFolder)
	if err != nil && !isNotFound(err) {
		return report, err
	}
	report.TrashItems = len(trash)
	devices, err := d.server.listRaw(ctx, stagingFolder)
	if err != nil && !isNotFound(err) {
		return report, err
	}
	for _, device := range devices {
		if device.IsDirectory && device.Name != d.deviceID {
			report.SafeDevices++
		}
	}
	report.Busy, err = d.controlFolderBusy(ctx, time.Now())
	return report, err
}

// controlFolderBusy says whether a Safe device holds a claim or is uploading to staging.
func (d *drive) controlFolderBusy(ctx context.Context, now time.Time) (bool, error) {
	claims, err := d.server.listRaw(ctx, claimsFolder)
	if err != nil && !isNotFound(err) {
		return false, err
	}
	for _, claim := range claims {
		leftover := strings.HasPrefix(claim.Name, "stale-") || strings.HasPrefix(claim.Name, "now-")
		if claim.IsDirectory && !leftover && (claim.Modified.IsZero() || now.Sub(claim.Modified) < claimLiveFor) {
			return true, nil
		}
	}
	devices, err := d.server.listRaw(ctx, stagingFolder)
	if err != nil && !isNotFound(err) {
		return false, err
	}
	for _, device := range devices {
		files, err := d.server.listRaw(ctx, stagingFolder+"/"+device.Name)
		if err != nil {
			return false, err
		}
		for _, file := range files {
			if file.Modified.IsZero() || stagingAge(file, now) < busyStagingWindow {
				return true, nil
			}
		}
	}
	return false, nil
}

// cleanControlFolder removes the control folder of a drive that no longer uses it, after a person
// agreed. The vault always stays: without its salt the drive can't be opened. It refuses while a
// Safe device is saving, judged by the server's clock, because clearing its claim or staging file
// would make that save start again.
func (d *drive) cleanControlFolder(ctx context.Context) (controlFolderReport, error) {
	if !d.unsafe {
		return controlFolderReport{}, errSafeNeedsControlFolder
	}
	report, err := d.controlFolderContents(ctx)
	if err != nil || !report.Exists {
		return report, err
	}
	now, err := serverNowAt(ctx, d.server, reservedPrefix+"now-"+uuid.NewString())
	if err != nil {
		return report, err
	}
	busy, err := d.controlFolderBusy(ctx, now)
	if err != nil {
		return report, err
	}
	if busy {
		return report, errControlFolderBusy
	}
	entries, err := d.server.listRaw(ctx, controlFolder)
	if err != nil {
		return report, err
	}
	for _, entry := range entries {
		if entry.Name == path.Base(vaultFolder) {
			continue
		}
		name := controlFolder + "/" + entry.Name
		if entry.IsDirectory {
			err = d.server.removeAll(ctx, name)
		} else {
			err = d.server.remove(ctx, name, false)
		}
		if err != nil {
			return report, err
		}
	}
	if !report.HasVault {
		if err := d.server.remove(ctx, controlFolder, true); err != nil {
			return report, err
		}
	}
	report.Removed, report.OtherEntries = true, 0
	return report, nil
}
