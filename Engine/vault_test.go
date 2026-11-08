// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func open(t *testing.T, id string, config driveConfig) (*vaultInfo, error) {
	t.Helper()
	config.ID = id
	config.Kind = "local"
	config.Encrypted = true
	t.Cleanup(func() { closeDrive(id) })
	return openDrive(context.Background(), config)
}

func readMarker(t *testing.T, server string, revision int) (string, vaultMarker) {
	t.Helper()
	file := filepath.Join(server, controlFolder, "vault", fmt.Sprintf("%d.json", revision))
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var marker vaultMarker
	if err := json.Unmarshal(raw, &marker); err != nil {
		t.Fatal(err)
	}
	return file, marker
}

func writeMarker(t *testing.T, file string, marker vaultMarker) {
	t.Helper()
	raw, err := json.Marshal(marker)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestSecondDeviceSharesTheVaultWithNoSaltTyped(t *testing.T) {
	ctx := context.Background()
	server := t.TempDir()
	first, err := open(t, "device-a", driveConfig{RootPath: server, VaultPassword: "shared", CreateVault: true})
	if err != nil {
		t.Fatal(err)
	}
	a, _ := lookupDrive("device-a")
	var counter atomic.Int64
	if _, err := a.upload(ctx, writeLocal(t, []byte("from A")), "note.txt", &counter); err != nil {
		t.Fatal(err)
	}

	second, err := open(t, "device-b", driveConfig{RootPath: server, VaultPassword: "shared"})
	if err != nil {
		t.Fatalf("second device: %v", err)
	}
	if first.VaultID != second.VaultID {
		t.Errorf("vault IDs differ: %s, %s", first.VaultID, second.VaultID)
	}
	b, _ := lookupDrive("device-b")
	items, err := b.list(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Path != "note.txt" {
		t.Errorf("second device sees %+v", items)
	}
}

// Re-adding a drive must reach the same key, not create another one.
func TestCreateVaultReusesAnExistingVault(t *testing.T) {
	server := t.TempDir()
	first, err := open(t, "add-1", driveConfig{RootPath: server, VaultPassword: "shared", CreateVault: true})
	if err != nil {
		t.Fatal(err)
	}
	again, err := open(t, "add-2", driveConfig{RootPath: server, VaultPassword: "shared", CreateVault: true})
	if err != nil {
		t.Fatal(err)
	}
	if first.VaultID != again.VaultID {
		t.Error("adding the drive again created a second vault")
	}
}

func TestWrongPasswordIsRefusedBeforeMounting(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "right", driveConfig{RootPath: server, VaultPassword: "correct", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	_, err := open(t, "wrong", driveConfig{RootPath: server, VaultPassword: "mistyped", CreateVault: true})
	if !errors.Is(err, errWrongPassword) {
		t.Fatalf("got %v", err)
	}
	if _, err := lookupDrive("wrong"); err == nil {
		t.Error("the drive opened despite the wrong password")
	}
}

func TestEditedMarkerIsDetected(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "tamper-1", driveConfig{RootPath: server, VaultPassword: "correct", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	file, marker := readMarker(t, server, 1)
	marker.Crypt.FilenameEncoding = "base64"
	writeMarker(t, file, marker)

	if _, err := open(t, "tamper-2", driveConfig{RootPath: server, VaultPassword: "correct"}); !errors.Is(err, errWrongPassword) {
		t.Fatalf("got %v", err)
	}
}

func TestFolderWithFilesAndNoMarkerIsNeverInitialized(t *testing.T) {
	server := t.TempDir()
	if err := os.WriteFile(filepath.Join(server, "existing.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := open(t, "occupied", driveConfig{RootPath: server, VaultPassword: "p", CreateVault: true})
	if !errors.Is(err, errVaultMissing) {
		t.Fatalf("got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(server, controlFolder)); !os.IsNotExist(statErr) {
		t.Error("a control folder was created anyway")
	}
}

func TestEmptyFolderNeedsPermissionToCreate(t *testing.T) {
	_, err := open(t, "no-create", driveConfig{RootPath: t.TempDir(), VaultPassword: "p"})
	if !errors.Is(err, errVaultNotCreated) {
		t.Fatalf("got %v", err)
	}
}

func TestPinnedVaultMismatchIsRefused(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "pin-1", driveConfig{RootPath: server, VaultPassword: "p", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	_, err := open(t, "pin-2", driveConfig{RootPath: server, VaultPassword: "p", ExpectedVaultID: "another"})
	if !errors.Is(err, errVaultMismatch) {
		t.Fatalf("got %v", err)
	}
}

func TestOlderRevisionThanPinnedIsRefused(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "roll-1", driveConfig{RootPath: server, VaultPassword: "p", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	_, err := open(t, "roll-2", driveConfig{RootPath: server, VaultPassword: "p", MinRevision: 2})
	if !errors.Is(err, errVaultRollback) {
		t.Fatalf("got %v", err)
	}
}

func TestHighestRevisionWinsAndRetiredIsRefused(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "retire-1", driveConfig{RootPath: server, VaultPassword: "p", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	file, marker := readMarker(t, server, 1)
	marker.Revision = 2
	marker.State = "retired"
	if err := marker.seal("p"); err != nil {
		t.Fatal(err)
	}
	writeMarker(t, filepath.Join(filepath.Dir(file), "2.json"), marker)

	_, err := open(t, "retire-2", driveConfig{RootPath: server, VaultPassword: "p"})
	if !errors.Is(err, errVaultRetired) {
		t.Fatalf("got %v", err)
	}
}

func TestNewerFormatIsRefused(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "future-1", driveConfig{RootPath: server, VaultPassword: "p", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	file, marker := readMarker(t, server, 1)
	marker.Format = vaultFormat + 1
	writeMarker(t, file, marker)

	_, err := open(t, "future-2", driveConfig{RootPath: server, VaultPassword: "p"})
	if !errors.Is(err, errVaultUnsupported) {
		t.Fatalf("got %v", err)
	}
}

func TestMalformedMarkerIsRefused(t *testing.T) {
	server := t.TempDir()
	if _, err := open(t, "broken-1", driveConfig{RootPath: server, VaultPassword: "p", CreateVault: true}); err != nil {
		t.Fatal(err)
	}
	file, _ := readMarker(t, server, 1)
	if err := os.WriteFile(file, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := open(t, "broken-2", driveConfig{RootPath: server, VaultPassword: "p"})
	if !errors.Is(err, errVaultMalformed) {
		t.Fatalf("got %v", err)
	}
}
