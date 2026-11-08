// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"golang.org/x/net/webdav"
)

// meddler stands between the engine and a real WebDAV server. It can change one request, the
// way a proxy or a misbehaving server would, and it notes how each staged file was moved in.
type meddler struct {
	handler http.Handler
	mu      sync.Mutex
	before  func(*http.Request)
	moves   []string
}

func (m *meddler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	m.mu.Lock()
	if request.Method == "MOVE" && strings.Contains(request.URL.Path, stagingFolder) {
		m.moves = append(m.moves, request.Header.Get("Overwrite"))
	}
	before := m.before
	m.mu.Unlock()
	if before != nil {
		before(request)
	}
	m.handler.ServeHTTP(writer, request)
}

func (m *meddler) setBefore(before func(*http.Request)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.before = before
}

func (m *meddler) takeMoves() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	moves := m.moves
	m.moves = nil
	return moves
}

// isCommit is the move that puts a staged upload in place.
func isCommit(request *http.Request) bool {
	return request.Method == "MOVE" && strings.Contains(request.URL.Path, stagingFolder)
}

// meddledDrive opens a plain drive through a meddler, so a test can see and write the server's files.
func meddledDrive(t *testing.T) (*drive, *meddler, string) {
	t.Helper()
	folder := t.TempDir()
	m := &meddler{handler: &webdav.Handler{FileSystem: webdav.Dir(folder), LockSystem: webdav.NewMemLS()}}
	server := httptest.NewServer(m)
	t.Cleanup(server.Close)
	id := driveID(t)
	config := driveConfig{ID: id, Kind: "webdav", URL: server.URL, DeviceID: "device-a", DeviceName: "MacBook"}
	if _, err := openDrive(context.Background(), config); err != nil {
		t.Fatalf("open drive: %v", err)
	}
	t.Cleanup(func() { closeDrive(id) })
	d, err := lookupDrive(id)
	if err != nil {
		t.Fatal(err)
	}
	return d, m, folder
}

// A server or proxy can answer success for an upload it cut short. Believing it would put a
// broken file over a good one, and tell macOS the save worked.
func TestAShortUploadIsNeverPublished(t *testing.T) {
	ctx := context.Background()
	d, m, folder := meddledDrive(t)
	var counter atomic.Int64
	first, err := d.save(ctx, writeLocal(t, []byte("the whole of the first version")), "report.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}

	// From here the server keeps half of every upload, and says it kept all of it.
	m.setBefore(func(request *http.Request) {
		if request.Method != http.MethodPut || !strings.Contains(request.URL.Path, stagingFolder) {
			return
		}
		sent, _ := io.ReadAll(request.Body)
		kept := sent[:len(sent)/2]
		request.Body = io.NopCloser(bytes.NewReader(kept))
		request.ContentLength = int64(len(kept))
	})
	second := writeLocal(t, []byte("a second version, which the server cuts short"))
	if _, err := d.save(ctx, second, "report.txt", first.Item.Version, &counter); !errors.Is(err, errShortUpload) {
		t.Fatalf("a short upload gave %v", err)
	}
	m.setBefore(nil)
	if got := read(t, d, "report.txt"); got != "the whole of the first version" {
		t.Errorf("the good file was replaced: %q", got)
	}
	if entries, _ := os.ReadDir(filepath.Join(folder, stagingFolder, "device-a")); len(entries) != 0 {
		t.Errorf("the short upload was left behind: %d entries", len(entries))
	}
}

// Overwrite: T on Apache removes the destination before the move, which is a moment with no
// file there, and replaces anything another tool put at a name thought free.
func TestASaveToAFreeNameNeverReplacesAnything(t *testing.T) {
	ctx := context.Background()
	d, m, _ := meddledDrive(t)
	var counter atomic.Int64
	created, err := d.save(ctx, writeLocal(t, []byte("new")), "free.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if moves := m.takeMoves(); len(moves) != 1 || moves[0] != "F" {
		t.Errorf("a new file was moved in with %v", moves)
	}
	if _, err := d.save(ctx, writeLocal(t, []byte("newer")), "free.txt", created.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}
	if moves := m.takeMoves(); len(moves) != 1 || moves[0] != "T" {
		t.Errorf("a replacing save was moved in with %v", moves)
	}
}

// Another tool writes the name in the moment between the check and the move. Its file keeps the
// name, and ours becomes the conflict copy, as with any peer.
func TestAFileThatAppearsAtTheLastMomentKeepsItsName(t *testing.T) {
	ctx := context.Background()
	d, m, folder := meddledDrive(t)
	var counter atomic.Int64
	m.setBefore(func(request *http.Request) {
		if !isCommit(request) {
			return
		}
		m.setBefore(nil)
		destination, err := url.Parse(request.Header.Get("Destination"))
		if err != nil {
			t.Error(err)
			return
		}
		if err := os.WriteFile(filepath.Join(folder, filepath.FromSlash(destination.Path)), []byte("written by another tool"), 0o600); err != nil {
			t.Error(err)
		}
	})
	result, err := d.save(ctx, writeLocal(t, []byte("ours")), "late.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictPath == "" {
		t.Fatal("no conflict copy was made")
	}
	if got := read(t, d, "late.txt"); got != "written by another tool" {
		t.Errorf("the other tool's file was replaced: %q", got)
	}
	if got := read(t, d, result.ConflictPath); got != "ours" {
		t.Errorf("conflict copy = %q", got)
	}
}

// A save that landed is reported as saved, even if it was cancelled during its final move.
// Otherwise the next save of the same edit meets it as a peer's version and makes a conflict copy.
func TestASaveThatLandedIsReportedEvenIfCancelled(t *testing.T) {
	d, m, _ := meddledDrive(t)
	var counter atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m.setBefore(func(request *http.Request) {
		if isCommit(request) {
			cancel()
		}
	})
	result, err := d.save(ctx, writeLocal(t, []byte("landed")), "landed.txt", "", &counter)
	if err != nil {
		t.Fatalf("a save that landed came back as %v", err)
	}
	if result.Item.Version == "" || result.ConflictPath != "" {
		t.Errorf("result = %+v", result)
	}
}

// The same for a rename.
func TestARenameThatLandedIsReportedEvenIfCancelled(t *testing.T) {
	d, m, _ := meddledDrive(t)
	var counter atomic.Int64
	if _, err := d.save(context.Background(), writeLocal(t, []byte("x")), "before.txt", "", &counter); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m.setBefore(func(request *http.Request) {
		if request.Method == "MOVE" && strings.HasSuffix(request.URL.Path, "before.txt") {
			cancel()
		}
	})
	moved, err := d.moveItem(ctx, "before.txt", "after.txt", "")
	if err != nil {
		t.Fatalf("a rename that landed came back as %v", err)
	}
	if moved.Path != "after.txt" {
		t.Errorf("moved = %+v", moved)
	}
}

// Each of these decides what macOS is told: try later, or stop and show a person why.
func TestBusyAndTooLargeServersSaySo(t *testing.T) {
	for status, want := range map[int]string{
		http.StatusRequestTimeout:        "unreachable",
		http.StatusTooManyRequests:       "server",
		http.StatusRequestEntityTooLarge: "tooLarge",
		http.StatusPreconditionFailed:    "versionMismatch",
	} {
		if got := classify(statusError(status)).Kind; got != want {
			t.Errorf("%d is %q, want %q", status, got, want)
		}
	}
	if got := classify(errNameTaken).Kind; got != "alreadyExists" {
		t.Errorf("a taken name is %q", got)
	}
}
