// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/xml"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/webdav"
)

// The races run on a real server when Tools/test-live-races.sh asks, because a local server can't
// show what a real one does between two requests. Each test makes its own new folder inside
// cloudmount-test and removes only that folder. Nothing above it is ever touched.
const (
	liveRounds = 3
	sftpPort   = 23

	// A little above what was measured, so that only a real change trips them.
	newFileRequests   = 15
	replacingRequests = 20
)

// liveParent is the test folder at the account's root. When cloudmount-test was gone, the user chose
// a hidden .cloudmount-test instead, on 2026-11-08. Nothing else is ever accepted.
func liveParent(t *testing.T) string {
	t.Helper()
	switch parent := os.Getenv("CM_LIVE_PARENT"); parent {
	case "", "cloudmount-test":
		return "cloudmount-test"
	case ".cloudmount-test":
		return parent
	default:
		t.Fatalf("refusing to use %q as the test folder", parent)
		return ""
	}
}

// liveRequest sends one WebDAV request that the commit layer doesn't make: creating and removing
// the test's own folder. Both protocols reach the same files on the server.
func liveRequest(t *testing.T, method, address string) (int, error) {
	t.Helper()
	if !strings.Contains(address, "/"+liveParent(t)+"/live-") {
		t.Fatalf("refusing to %s anything but a live test folder", method)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, method, address+"/", nil)
	if err != nil {
		return 0, err
	}
	request.SetBasicAuth(os.Getenv("CM_TEST_WEBDAV_USER"), os.Getenv("CM_TEST_WEBDAV_PASSWORD"))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	return response.StatusCode, nil
}

func liveServer(kind string) func(*testing.T, string) driveConfig {
	return func(t *testing.T, _ string) driveConfig {
		t.Helper()
		base := strings.TrimSuffix(os.Getenv("CM_TEST_WEBDAV_URL"), "/")
		address, err := url.Parse(base)
		if err != nil || address.Hostname() == "" {
			t.Fatal("CM_TEST_WEBDAV_URL isn't set")
		}
		folder := fmt.Sprintf("%s/live-%s-%d", liveParent(t), kind, time.Now().UnixNano())
		if status, err := liveRequest(t, "MKCOL", base+"/"+folder); err != nil || status != http.StatusCreated {
			t.Fatalf("couldn't make the test folder: status %d, %v", status, err)
		}
		// A dropped connection here says nothing about the code under test.
		t.Cleanup(func() {
			var status int
			var err error
			for range 3 {
				if status, err = liveRequest(t, "DELETE", base+"/"+folder); err == nil && status < 300 {
					return
				}
				time.Sleep(2 * time.Second)
			}
			t.Logf("left %s behind: status %d, %v", folder, status, err)
		})

		config := driveConfig{
			Kind: kind,
			User: os.Getenv("CM_TEST_WEBDAV_USER"), Password: os.Getenv("CM_TEST_WEBDAV_PASSWORD"),
		}
		if kind == "webdav" {
			config.URL = base + "/" + folder
			return config
		}
		key, err := probeHostKey(context.Background(), address.Hostname(), sftpPort)
		if err != nil {
			t.Fatalf("reading the host key: %v", err)
		}
		config.Host, config.Port, config.RootPath, config.HostKey = address.Hostname(), sftpPort, folder, key.Key
		return config
	}
}

// liveTests are the races that need nothing but the server: none of them looks at its disk.
var liveTests = []struct {
	name string
	test func(*testing.T)
}{
	{"APeersSaveIsNeverOverwritten", TestAPeersSaveIsNeverOverwritten},
	{"SimultaneousSaves", TestSimultaneousSavesKeepBothVersions},
	{"ANewFileOnATakenName", TestANewFileOnATakenNameBecomesAConflictCopy},
	{"AnEditOfADeletedFile", TestAnEditOfAFileAPeerDeletedIsPutBack},
	{"ASaveStandsAside", TestASaveStandsAsideForAFolderOperation},
	{"AFolderMoveWaits", TestAFolderMoveWaitsForALiveSave},
	{"AChildSaveAgainstAMove", TestAChildSaveAgainstAFolderMoveLosesNothing},
	{"AChildSaveAgainstATrash", TestAChildSaveAgainstAFolderTrashLosesNothing},
}

func TestLiveRaces(t *testing.T) {
	kind := os.Getenv("CM_LIVE_SERVER")
	if kind == "" {
		t.Skip("Tools/test-live-races.sh runs this against a real server")
	}
	testServer = liveServer(kind)
	defer func() { testServer = nil }()
	for round := 1; round <= liveRounds; round++ {
		for _, live := range liveTests {
			t.Run(fmt.Sprintf("%s-%d", live.name, round), live.test)
		}
	}
}

// A video made on one device and opened on another, through Apache rather than the local server.
func TestLiveBigEncryptedFile(t *testing.T) {
	kind := os.Getenv("CM_LIVE_SERVER")
	if kind == "" {
		t.Skip("Tools/test-live-races.sh runs this against a real server")
	}
	checkBigEncryptedRoundTrip(t, liveServer(kind)(t, ""))
}

// How long a save takes on a real server decides how a folder of small files feels.
func TestLiveSaveTime(t *testing.T) {
	kind := os.Getenv("CM_LIVE_SERVER")
	if kind == "" {
		t.Skip("Tools/test-live-races.sh runs this against a real server")
	}
	testServer = liveServer(kind)
	defer func() { testServer = nil }()
	a, _, _ := twoDevices(t)
	ctx := context.Background()
	var counter atomic.Int64

	timed := func(label string, save func(run int) error) {
		const saves = 20
		started := time.Now()
		for run := range saves {
			if err := save(run); err != nil {
				t.Fatal(err)
			}
		}
		t.Logf("%s: %v each", label, (time.Since(started) / saves).Round(time.Millisecond))
	}
	versions := map[int]string{}
	timed("a new file", func(run int) error {
		result, err := a.save(ctx, writeLocal(t, []byte("first")), fmt.Sprintf("file-%d.txt", run), "", &counter)
		versions[run] = result.Item.Version
		return err
	})
	timed("replacing a file", func(run int) error {
		_, err := a.save(ctx, writeLocal(t, []byte("second")), fmt.Sprintf("file-%d.txt", run), versions[run], &counter)
		return err
	})
}

// counted is a WebDAV server that notes each request it gets.
type counted struct {
	handler http.Handler
	mu      sync.Mutex
	methods map[string]int
}

func (c *counted) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	c.mu.Lock()
	c.methods[request.Method]++
	c.mu.Unlock()
	c.handler.ServeHTTP(writer, request)
}

// take returns how many requests came in since the last call, and which.
func (c *counted) take() (int, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	total, parts := 0, []string{}
	for method, count := range c.methods {
		total += count
		parts = append(parts, fmt.Sprintf("%s %d", method, count))
	}
	sort.Strings(parts)
	clear(c.methods)
	return total, strings.Join(parts, ", ")
}

// A folder of small files costs one set of these per file, so the count matters as much as speed.
// The limits catch a change that quietly adds round trips to every save. It runs on a server that
// refuses file details and on one that keeps them, which costs a save one more request.
func TestRequestsPerSave(t *testing.T) {
	for name, files := range map[string]func(string) webdav.FileSystem{
		"refusing details": func(folder string) webdav.FileSystem { return webdav.Dir(folder) },
		"keeping details": func(folder string) webdav.FileSystem {
			return &propsFS{Dir: webdav.Dir(folder), props: map[string]map[xml.Name]webdav.Property{}}
		},
	} {
		t.Run(name, func(t *testing.T) { checkRequestsPerSave(t, files(t.TempDir())) })
	}
}

func checkRequestsPerSave(t *testing.T, files webdav.FileSystem) {
	requireRclone(t)
	ctx := context.Background()
	server := &counted{
		handler: &webdav.Handler{FileSystem: files, LockSystem: webdav.NewMemLS()},
		methods: map[string]int{},
	}
	running := httptest.NewServer(server)
	t.Cleanup(running.Close)
	d := openEncrypted(t, strings.ReplaceAll(driveID(t), "/", "-"), driveConfig{Kind: "webdav", URL: running.URL, DeviceID: "device-a"})
	var counter atomic.Int64

	// The first saves make the folders, and the marker check runs at most every 5 seconds, so
	// the count that matters comes after both have settled.
	warm, err := d.save(ctx, writeLocal(t, []byte("warm")), "warm.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.save(ctx, writeLocal(t, []byte("warm again")), "warm.txt", warm.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}

	server.take()
	created, err := d.save(ctx, writeLocal(t, []byte("first")), "file.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	total, detail := server.take()
	t.Logf("a new file: %d requests (%s)", total, detail)
	if total > newFileRequests {
		t.Errorf("a new file took %d requests, over the limit of %d: %s", total, newFileRequests, detail)
	}

	if _, err := d.save(ctx, writeLocal(t, []byte("second")), "file.txt", created.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}
	total, detail = server.take()
	t.Logf("replacing a file: %d requests (%s)", total, detail)
	if total > replacingRequests {
		t.Errorf("replacing a file took %d requests, over the limit of %d: %s", total, replacingRequests, detail)
	}
}
