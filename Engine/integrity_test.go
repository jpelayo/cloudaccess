// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/net/webdav"
)

// These came from the integrity review of 2026-11-09. Each failed before its fix.

func init() {
	// A test server replaces a file in one step, so there's nothing to wait for.
	policyLookAgain = func(context.Context) {}
}

// MARK: A policy that's missing

func policyOnDisk(folder string) string {
	return filepath.Join(folder, ".cloudmount", "policy.json")
}

// Apache removes the old policy before moving the new one in, so a pass can find none for a
// moment. That moment mustn't mean the default week, or a longer retention loses what it keeps.
func TestAPolicyMissingForAMomentNeverShortensRetention(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	id := trashOldItem(t, d, folder, defaultRetentionDays+3)
	// Written by another device, so this one has never read it.
	content, err := json.Marshal(policyLasting(30 * secondsPerDay))
	if err != nil {
		t.Fatal(err)
	}
	restore := policyLookAgain
	defer func() { policyLookAgain = restore }()
	// Back by the second look, as it is once a replace finishes.
	policyLookAgain = func(context.Context) {
		if err := os.WriteFile(policyOnDisk(folder), content, 0o600); err != nil {
			t.Error(err)
		}
	}

	result, err := d.maintain(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if result.PurgedEntries != 0 {
		t.Fatal("a 10-day-old entry was purged while a 30-day policy was being replaced")
	}
	if result.PurgeSkipped != "" {
		t.Fatalf("the second look found the policy, so the pass should have run: %s", result.PurgeSkipped)
	}
	if _, err := os.Stat(filepath.Join(folder, ".cloudmount", "trash", id)); err != nil {
		t.Fatalf("the entry should still be there: %v", err)
	}
}

// A drive that has shown a policy and then has none is uncertain, and purging can't be undone.
func TestAPolicyThatVanishesStopsThePurge(t *testing.T) {
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	ctx := context.Background()
	if err := d.setPolicy(ctx, drivePolicy{TrashRetentionDays: 30}); err != nil {
		t.Fatal(err)
	}
	if _, err := d.maintain(ctx); err != nil {
		t.Fatal(err)
	}
	id := trashOldItem(t, d, folder, defaultRetentionDays+3)
	if err := os.Remove(policyOnDisk(folder)); err != nil {
		t.Fatal(err)
	}

	result, err := d.maintain(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if result.PurgedEntries != 0 {
		t.Fatal("a 10-day-old entry was purged when a 30-day policy went missing")
	}
	if result.PurgeSkipped == "" {
		t.Fatal("skipping a purge should be reported")
	}
	if _, err := os.Stat(filepath.Join(folder, ".cloudmount", "trash", id)); err != nil {
		t.Fatalf("the entry should still be there: %v", err)
	}
}

// MARK: A move only partly done

// partlyMovingServer moves only the first member of a folder taken out of the trash, and answers
// 207 Multi-Status, as RFC 4918 lets a server do when some members fail.
type partlyMovingServer struct {
	handler http.Handler
	folder  string
	partly  atomic.Bool
}

func (s *partlyMovingServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != "MOVE" || !s.partly.Load() || !strings.Contains(r.URL.Path, "/"+trashFolder+"/") {
		s.handler.ServeHTTP(w, r)
		return
	}
	destination, err := url.Parse(r.Header.Get("Destination"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	from := filepath.Join(s.folder, filepath.FromSlash(r.URL.Path))
	to := filepath.Join(s.folder, filepath.FromSlash(destination.Path))
	members, err := os.ReadDir(from)
	if err != nil || len(members) < 2 {
		http.Error(w, "expected a folder with two members", http.StatusInternalServerError)
		return
	}
	if err := os.MkdirAll(to, 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	first := members[0].Name()
	if err := os.Rename(filepath.Join(from, first), filepath.Join(to, first)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.WriteHeader(http.StatusMultiStatus)
	fmt.Fprintf(w, `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:"><D:response><D:href>%s%s</D:href>
<D:status>HTTP/1.1 403 Forbidden</D:status></D:response></D:multistatus>`, r.URL.Path, members[1].Name())
}

// A restore deletes the trash entry once the folder is back. If the server moved only part of
// it, the rest is still in the entry, and deleting that would lose it for good.
func TestAFolderOnlyPartlyRestoredStaysInTheTrash(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	server := &partlyMovingServer{
		handler: &webdav.Handler{FileSystem: webdav.Dir(folder), LockSystem: webdav.NewMemLS()},
		folder:  folder,
	}
	running := httptest.NewServer(server)
	t.Cleanup(running.Close)
	d := openSFTP(t, driveConfig{Kind: "webdav", URL: running.URL})
	saved(t, d, "folder/one.txt", "1")
	saved(t, d, "folder/deep/two.txt", "2")
	if err := d.trash(ctx, "folder", ""); err != nil {
		t.Fatal(err)
	}
	entries, err := d.trashEntries(ctx)
	if err != nil || len(entries) != 1 {
		t.Fatalf("entries %v %v", entries, err)
	}

	server.partly.Store(true)
	_, err = d.restoreFromTrash(ctx, entries[0].ID)
	server.partly.Store(false)

	if err == nil {
		t.Fatal("a restore the server only partly did was reported as done")
	}
	left := filepath.Join(folder, trashFolder, entries[0].ID, "item", "one.txt")
	if _, err := os.Stat(left); err != nil {
		t.Fatalf("what the server didn't move was deleted from the trash: %v", err)
	}
}

// MARK: A gateway's error at the final move

// A proxy can answer 502 or 504 while the server behind it still carries the move out. If the
// claim went then, a peer could commit, and this move could land on top of its save.
func TestAGatewayErrorKeepsTheClaimSoNoPeerCanCommit(t *testing.T) {
	for _, status := range []int{http.StatusInternalServerError, http.StatusBadGateway, http.StatusGatewayTimeout} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			onBothServers(t, func(t *testing.T, d *drive, _ string) {
				var counter atomic.Int64
				ctx := context.Background()
				held := &heldServer{
					rawServer: d.server, reached: make(chan struct{}), proceed: make(chan struct{}),
					fail: statusError(status),
				}
				close(held.proceed)
				real := d.server
				d.server = held
				_, err := d.save(ctx, writeLocal(t, []byte("mine")), "file.txt", "", &counter)
				d.server = real
				if !errors.Is(err, errResultUnknown) {
					t.Fatalf("a %d at the final move should be an unknown result, got %v", status, err)
				}
				if _, err := d.server.statRaw(ctx, claimPath(d.rawFile("file.txt"))); err != nil {
					t.Fatalf("the claim should stay until it expires: %v", err)
				}
			})
		})
	}
}

// A full server has said what happened, so nothing is held for ten minutes.
func TestAFullServerStillReleasesTheClaim(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		var counter atomic.Int64
		ctx := context.Background()
		held := &heldServer{
			rawServer: d.server, reached: make(chan struct{}), proceed: make(chan struct{}),
			fail: statusError(http.StatusInsufficientStorage),
		}
		close(held.proceed)
		real := d.server
		d.server = held
		_, err := d.save(ctx, writeLocal(t, []byte("mine")), "file.txt", "", &counter)
		d.server = real
		if err == nil || errors.Is(err, errResultUnknown) {
			t.Fatalf("a full server is a known result, got %v", err)
		}
		if _, err := d.server.statRaw(ctx, claimPath(d.rawFile("file.txt"))); !isNotFound(err) {
			t.Fatalf("a known result releases the claim: %v", err)
		}
	})
}
