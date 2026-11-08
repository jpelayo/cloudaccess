// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"path"
	"strings"
	"sync"
	"time"
)

const (
	policyFile = controlFolder + "/policy.json"
	// defaultRetentionDays is how long deleted items stay in the server's trash.
	defaultRetentionDays = 7
	// minRetentionDays and maxRetentionDays bound what a policy can say. Past this, days overflow
	// a duration, and a value that makes no sense is treated as unreadable.
	minRetentionDays = 1
	maxRetentionDays = 3650
	// minRetentionSeconds is the shortest exact time a policy can give.
	minRetentionSeconds = 60
	secondsPerDay       = 24 * 60 * 60
	// Another device's staging files are only cleared after this long, which no upload can
	// outlast. This device's own go sooner, though not soon, because its app and its extension
	// are separate processes, so it can't know nothing is running.
	otherStagingLifetime = 30 * 24 * time.Hour
	ownStagingLifetime   = 7 * 24 * time.Hour
	// leftoverClaimLifetime clears takeover and clock-probe folders a crash left behind.
	leftoverClaimLifetime = time.Hour
	maxControlFileBytes   = 1 << 20
)

var (
	errNotInTrash       = errors.New("this item is no longer in the trash")
	errNotEncrypted     = errors.New("this drive isn't encrypted")
	errPolicyUnreadable = errors.New("the drive's retention policy can't be read")
	errDamagedEntry     = errors.New("this deleted item's details are damaged, so it can't be restored")
)

// checkRestorePath refuses a path read from the trash that isn't a plain path inside the drive.
// On a plain drive anyone with write access to the server can edit it, so it gets the same checks
// as a new name, and more.
func checkRestorePath(p string) error {
	if p == "" || strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00") {
		return errDamagedEntry
	}
	for _, name := range strings.Split(p, "/") {
		if name == "" || name == "." || name == ".." || name == controlFolder || strings.HasPrefix(name, ".cm-") {
			return errDamagedEntry
		}
		if len(name) > maxServerNameBytes {
			return errDamagedEntry
		}
	}
	return nil
}

// readControlFile reads a small file from the control folder, decrypting it if the drive is.
func (d *drive) readControlFile(ctx context.Context, remote string) ([]byte, error) {
	object, err := d.plain.NewObject(ctx, remote)
	if err != nil {
		return nil, err
	}
	in, err := object.Open(ctx)
	if err != nil {
		return nil, err
	}
	defer in.Close()
	if d.cipher == nil {
		return io.ReadAll(io.LimitReader(in, maxControlFileBytes))
	}
	decrypted, err := d.cipher.DecryptData(in)
	if err != nil {
		return nil, err
	}
	defer decrypted.Close()
	return io.ReadAll(io.LimitReader(decrypted, maxControlFileBytes))
}

// drivePolicy is shared by every device on a drive, so they all agree on retention.
type drivePolicy struct {
	// TrashRetentionDays is all an older build can read, so it's the exact time rounded up: a
	// device that can't see the exact time keeps things longer, never shorter.
	TrashRetentionDays int `json:"trashRetentionDays"`
	// TrashRetentionSeconds is the exact time. A policy from an older build doesn't have one.
	TrashRetentionSeconds int64 `json:"trashRetentionSeconds,omitempty"`
}

// policyLasting is the policy that keeps deleted items for this long.
func policyLasting(seconds int64) drivePolicy {
	return drivePolicy{
		TrashRetentionDays:    int((seconds + secondsPerDay - 1) / secondsPerDay),
		TrashRetentionSeconds: seconds,
	}
}

// makesSense is false for anything no device would have written. The days can't be shorter than
// the exact time, because an older build would then purge what this one is keeping.
func (p drivePolicy) makesSense() bool {
	if p.TrashRetentionDays < minRetentionDays || p.TrashRetentionDays > maxRetentionDays {
		return false
	}
	if p.TrashRetentionSeconds == 0 {
		return true
	}
	return p.TrashRetentionSeconds >= minRetentionSeconds &&
		p.TrashRetentionSeconds <= int64(p.TrashRetentionDays)*secondsPerDay
}

func (p drivePolicy) retention() time.Duration {
	if p.TrashRetentionSeconds > 0 {
		return time.Duration(p.TrashRetentionSeconds) * time.Second
	}
	return time.Duration(p.TrashRetentionDays) * 24 * time.Hour
}

// retentionInfo is how long a drive keeps what's deleted, as the app is told it.
type retentionInfo struct {
	TrashRetentionSeconds int64 `json:"trashRetentionSeconds"`
}

func (d *drive) retentionInfo(ctx context.Context) (retentionInfo, error) {
	policy, err := d.policy(ctx)
	if err != nil {
		return retentionInfo{}, err
	}
	return retentionInfo{TrashRetentionSeconds: int64(policy.retention() / time.Second)}, nil
}

// policy reads the shared policy. No policy at all means the default. Anything that can't be
// read or doesn't make sense is an error: it might be hiding a longer retention than the default,
// and purging can't be undone, so uncertainty must never shorten it.
func (d *drive) policy(ctx context.Context) (drivePolicy, error) {
	content, err := d.readControlFile(ctx, policyFile)
	if err != nil {
		if isNotFound(err) {
			return drivePolicy{TrashRetentionDays: defaultRetentionDays}, nil
		}
		return drivePolicy{}, err
	}
	var policy drivePolicy
	if err := json.Unmarshal(content, &policy); err != nil {
		return drivePolicy{}, errPolicyUnreadable
	}
	if !policy.makesSense() {
		return drivePolicy{}, errPolicyUnreadable
	}
	return policy, nil
}

func (d *drive) setPolicy(ctx context.Context, policy drivePolicy) error {
	if !policy.makesSense() {
		return errPolicyUnreadable
	}
	encoded, err := json.Marshal(policy)
	if err != nil {
		return err
	}
	return d.publishControlFile(ctx, policyFile, encoded)
}

// trashInfo is one deleted item, as a person sees it.
type trashInfo struct {
	ID           string `json:"id"`
	OriginalPath string `json:"originalPath"`
	DeletedAt    int64  `json:"deletedAt"`
	Device       string `json:"device"`
	IsDirectory  bool   `json:"isDirectory"`
	// IsDamaged means its details can't be trusted, so it can't be restored. It goes by age.
	IsDamaged bool `json:"isDamaged"`
	// IsVersion means a save replaced this. The file itself is still on the drive.
	IsVersion bool `json:"isVersion"`
}

func isNotFound(err error) bool {
	return classify(err).Kind == "notFound"
}

// trashReaders is how many entries are read at once. Each takes two requests, and every save adds
// an entry for the version it replaced, so a busy drive can hold thousands of them.
const trashReaders = 4

// trashEntries lists what can be restored. An entry with no metadata is a crash leftover.
func (d *drive) trashEntries(ctx context.Context) ([]trashInfo, error) {
	if d.server == nil {
		return []trashInfo{}, nil
	}
	entries, err := d.server.listRaw(ctx, trashFolder)
	if err != nil {
		if isNotFound(err) {
			return []trashInfo{}, nil
		}
		return nil, err
	}

	found := make([]*trashInfo, len(entries))
	slots := make(chan struct{}, trashReaders)
	var group sync.WaitGroup
	for index, entry := range entries {
		if !entry.IsDirectory {
			continue
		}
		slots <- struct{}{}
		group.Add(1)
		go func() {
			defer group.Done()
			defer func() { <-slots }()
			// The recover at the C boundary can't see this goroutine, and a panic here would end
			// the process. An entry that can't be read is simply left out.
			defer func() { _ = recover() }()
			found[index] = d.trashEntry(ctx, entry)
		}()
	}
	group.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	items := make([]trashInfo, 0, len(entries))
	for _, item := range found {
		if item != nil {
			items = append(items, *item)
		}
	}
	return items, nil
}

// trashEntry reads one entry, or nil if it has no item in it.
func (d *drive) trashEntry(ctx context.Context, entry rawEntry) *trashInfo {
	item, err := d.server.statRaw(ctx, trashFolder+"/"+entry.Name+"/item")
	if err != nil {
		return nil
	}
	info := trashInfo{
		ID: entry.Name, IsDirectory: item.IsDirectory, DeletedAt: entry.Modified.Unix(),
		IsVersion: strings.HasPrefix(entry.Name, versionPrefix),
	}
	var meta trashEntry
	content, err := d.readControlFile(ctx, trashFolder+"/"+entry.Name+"/meta")
	if err == nil && json.Unmarshal(content, &meta) == nil && checkRestorePath(meta.OriginalPath) == nil {
		info.OriginalPath, info.DeletedAt, info.Device = meta.OriginalPath, meta.DeletedAt, meta.Device
	} else {
		info.IsDamaged = true
	}
	return &info
}

// restoreFromTrash moves an item back. Missing folders are recreated, and a name that's since
// been taken is restored beside it as a conflict copy, so nothing is replaced.
func (d *drive) restoreFromTrash(ctx context.Context, id string) (remoteItem, error) {
	if strings.ContainsAny(id, "/\\") || id == "" || id == "." || id == ".." {
		return remoteItem{}, errNotInTrash
	}
	entryPath := trashFolder + "/" + id
	content, err := d.readControlFile(ctx, entryPath+"/meta")
	if err != nil {
		if isNotFound(err) {
			return remoteItem{}, errNotInTrash
		}
		return remoteItem{}, err
	}
	var meta trashEntry
	if err := json.Unmarshal(content, &meta); err != nil {
		return remoteItem{}, errDamagedEntry
	}
	if err := checkRestorePath(meta.OriginalPath); err != nil {
		return remoteItem{}, err
	}
	if err := d.checkName(meta.OriginalPath); err != nil {
		return remoteItem{}, errDamagedEntry
	}
	item, err := d.server.statRaw(ctx, entryPath+"/item")
	if err != nil {
		if isNotFound(err) {
			return remoteItem{}, errNotInTrash
		}
		return remoteItem{}, err
	}

	target := meta.OriginalPath
	if _, found, err := d.exists(ctx, target); err != nil {
		return remoteItem{}, err
	} else if found {
		target = path.Join(path.Dir(target), conflictName(path.Base(target), d.deviceName, time.Now(), 1))
		target = strings.TrimPrefix(target, "./")
	}

	var restored remoteItem
	move := func(stillHeld func() error) error {
		// A purge may have won before the claim did.
		if _, err := d.server.statRaw(ctx, entryPath+"/item"); err != nil {
			if isNotFound(err) {
				return errNotInTrash
			}
			return err
		}
		if _, found, err := d.exists(ctx, target); err != nil {
			return err
		} else if found {
			return errClaimBusy
		}
		if err := d.ensureParent(ctx, target); err != nil {
			return err
		}
		if err := stillHeld(); err != nil {
			return err
		}
		if err := d.commitMove(ctx, entryPath+"/item", d.rawFile(target), item.IsDirectory, false); err != nil {
			return err
		}
		restored, err = d.serverStat(ctx, target)
		return err
	}
	// Restore and purge take the same claim on the entry, so one can't pull it from under the other.
	if item.IsDirectory {
		err = d.withStructure(ctx, func(stillHeld func() error) error {
			entry, err := acquireClaim(ctx, d.server, entryPath)
			if err != nil {
				return err
			}
			err = move(func() error {
				if err := stillHeld(); err != nil {
					return err
				}
				return entry.stillOwned(ctx, d.server)
			})
			if !errors.Is(err, errResultUnknown) {
				releaseClaim(d.server, entry)
			}
			return err
		})
	} else {
		err = d.withClaims(ctx, []string{d.rawFile(target), entryPath}, move)
	}
	if err != nil {
		return remoteItem{}, err
	}
	_ = d.server.removeAll(ctx, entryPath)
	return restored, nil
}

// maintenanceResult says what a maintenance pass cleared.
type maintenanceResult struct {
	PurgedEntries int `json:"purgedEntries"`
	SweptFiles    int `json:"sweptFiles"`
	// PurgeSkipped says why no trash was purged on this pass, for the diagnostics.
	PurgeSkipped string `json:"purgeSkipped,omitempty"`
	// RetentionSeconds tells the app how soon to look again, once the policy could be read.
	RetentionSeconds int64 `json:"retentionSeconds,omitempty"`
}

// purgeEntry removes one trash entry for good. It takes the claim a restore takes, and checks the
// age again under it, because this can't be undone.
func (d *drive) purgeEntry(ctx context.Context, entryPath string, retention time.Duration) bool {
	held, err := acquireClaim(ctx, d.server, entryPath)
	if err != nil {
		return false
	}
	defer releaseClaim(d.server, held)
	entry, err := d.server.statRaw(ctx, entryPath)
	if err != nil || entry.Modified.IsZero() {
		return false
	}
	now, err := serverNow(ctx, d.server)
	if err != nil || now.Sub(entry.Modified) <= retention {
		return false
	}
	if held.stillOwned(ctx, d.server) != nil {
		return false
	}
	return d.server.removeAll(ctx, entryPath) == nil
}

// stagingAge is how long a staged file has been there. The name says when its upload began, and
// the later of that and its modified time is used, so neither an old document nor a wrong device
// clock can make a live upload look abandoned.
func stagingAge(file rawEntry, now time.Time) time.Duration {
	newest := file.Modified
	if started, ok := stagingStarted(file.Name); ok && started.After(newest) {
		newest = started
	}
	return now.Sub(newest)
}

// maintain clears what's past its time: trash beyond the shared retention, abandoned staging
// files, and folders left by crashed claims. Ages come from the server's clock, so a device
// with a wrong clock can't purge early, and purging twice is harmless.
func (d *drive) maintain(ctx context.Context) (maintenanceResult, error) {
	var result maintenanceResult
	if d.server == nil {
		return result, nil
	}
	// The probe needs the claims folder, which a new drive may not have yet.
	if err := d.server.ensureFolder(ctx, claimsFolder); err != nil {
		return result, err
	}
	now, err := serverNow(ctx, d.server)
	if err != nil {
		return result, err
	}

	policy, policyErr := d.policy(ctx)
	if policyErr != nil {
		// Nothing irreversible runs on uncertain evidence, so trash waits for the next pass.
		result.PurgeSkipped = policyErr.Error()
	} else {
		retention := policy.retention()
		result.RetentionSeconds = int64(retention / time.Second)
		entries, err := d.server.listRaw(ctx, trashFolder)
		if err != nil && !isNotFound(err) {
			return result, err
		}
		for _, entry := range entries {
			lifetime := retention
			if strings.HasPrefix(entry.Name, versionPrefix) {
				lifetime = min(retention, versionLifetime)
			}
			if !entry.Modified.IsZero() && now.Sub(entry.Modified) > lifetime &&
				d.purgeEntry(ctx, trashFolder+"/"+entry.Name, lifetime) {
				result.PurgedEntries++
			}
		}
	}

	devices, err := d.server.listRaw(ctx, stagingFolder)
	if err != nil && !isNotFound(err) {
		return result, err
	}
	for _, device := range devices {
		lifetime := otherStagingLifetime
		if device.Name == d.deviceID {
			lifetime = ownStagingLifetime
		}
		files, err := d.server.listRaw(ctx, stagingFolder+"/"+device.Name)
		if err != nil {
			continue
		}
		for _, file := range files {
			if !file.Modified.IsZero() && stagingAge(file, now) > lifetime {
				if d.server.remove(ctx, stagingFolder+"/"+device.Name+"/"+file.Name, false) == nil {
					result.SweptFiles++
				}
			}
		}
	}

	claims, err := d.server.listRaw(ctx, claimsFolder)
	if err != nil {
		return result, err
	}
	for _, claim := range claims {
		leftover := strings.HasPrefix(claim.Name, "stale-") || strings.HasPrefix(claim.Name, "now-")
		if leftover && !claim.Modified.IsZero() && now.Sub(claim.Modified) > leftoverClaimLifetime {
			removeClaimFolder(ctx, d.server, claimsFolder+"/"+claim.Name)
		}
	}
	return result, nil
}

// retireVault adds a retired revision, so every client stops writing to this vault once it
// checks the marker. The files stay readable with the password.
func (d *drive) retireVault(ctx context.Context) error {
	if d.vault == nil {
		return errNotEncrypted
	}
	claim, err := acquireClaim(ctx, d.server, vaultFolder)
	if err != nil {
		return err
	}
	defer releaseClaim(d.server, claim)
	marker, err := loadVaultMarker(ctx, d.plain)
	if err != nil {
		return err
	}
	if marker == nil {
		return errVaultMissing
	}
	// Sealing vouches for every field, so an edited marker must not get this far.
	if err := marker.verify(d.vault.password); err != nil {
		return err
	}
	next := *marker
	next.State = "retired"
	next.Revision++
	if err := next.seal(d.vault.password); err != nil {
		return err
	}
	return writeVaultMarker(ctx, d.plain, next)
}

// vaultDetails is what a recovery kit needs to reach the files with plain rclone.
type vaultDetails struct {
	VaultID                 string `json:"vaultID"`
	Salt                    string `json:"salt"`
	FilenameEncryption      string `json:"filenameEncryption"`
	DirectoryNameEncryption bool   `json:"directoryNameEncryption"`
	FilenameEncoding        string `json:"filenameEncoding"`
}

func (d *drive) vaultDetails(ctx context.Context) (vaultDetails, error) {
	if d.vault == nil {
		return vaultDetails{}, errNotEncrypted
	}
	marker, err := loadVaultMarker(ctx, d.plain)
	if err != nil {
		return vaultDetails{}, err
	}
	if marker == nil {
		return vaultDetails{}, errVaultMissing
	}
	// A recovery kit is only useful if what it says is true.
	if err := marker.verify(d.vault.password); err != nil {
		return vaultDetails{}, err
	}
	return vaultDetails{
		VaultID:                 marker.VaultID,
		Salt:                    marker.Salt,
		FilenameEncryption:      marker.Crypt.FilenameEncryption,
		DirectoryNameEncryption: marker.Crypt.DirectoryNameEncryption,
		FilenameEncoding:        marker.Crypt.FilenameEncoding,
	}, nil
}
