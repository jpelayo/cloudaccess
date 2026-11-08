// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"testing"
	"time"
)

// leakCycles is kept short for everyday runs. CM_LEAK_CYCLES runs the release gate's thousands.
func leakCycles() int {
	if value, err := strconv.Atoi(os.Getenv("CM_LEAK_CYCLES")); err == nil && value > 0 {
		return value
	}
	return 200
}

// openFiles counts this process's descriptors, which include sockets.
func openFiles(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir("/dev/fd")
	if err != nil {
		t.Fatal(err)
	}
	return len(entries)
}

// settledCounts waits for finished work to wind down, because a closed connection's goroutines
// take a moment to leave, and returns what's still alive.
func settledCounts(t *testing.T, goroutines, files int, patience time.Duration) (int, int) {
	t.Helper()
	deadline := time.Now().Add(patience)
	for {
		runtime.GC()
		nowGoroutines, nowFiles := runtime.NumGoroutine(), openFiles(t)
		if (nowGoroutines <= goroutines && nowFiles <= files) || time.Now().After(deadline) {
			return nowGoroutines, nowFiles
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// expectNoGrowth runs a cycle many times and checks it returns to where it started. A few warm-up
// rounds come first, because shared pools fill once and then stay the same size.
func expectNoGrowth(t *testing.T, patience time.Duration, cycle func(round int)) {
	t.Helper()
	for round := 0; round < 10; round++ {
		cycle(round)
	}
	const slack = 8
	goroutines, files := settledCounts(t, 0, 0, 2*time.Second)
	cycles := leakCycles()
	for round := 0; round < cycles; round++ {
		cycle(round)
	}
	afterGoroutines, afterFiles := settledCounts(t, goroutines+slack, files+slack, patience)
	t.Logf("%d cycles: goroutines %d to %d, descriptors %d to %d",
		cycles, goroutines, afterGoroutines, files, afterFiles)
	if afterGoroutines > goroutines+slack {
		t.Errorf("goroutines grew from %d to %d", goroutines, afterGoroutines)
	}
	if afterFiles > files+slack {
		t.Errorf("descriptors grew from %d to %d", files, afterFiles)
	}
}

func openAndClose(t *testing.T, config driveConfig, name string, round int) {
	t.Helper()
	config.ID = fmt.Sprintf("%s-%s-%d", driveID(t), name, round)
	config.DeviceID = "device-a"
	if _, err := openDrive(context.Background(), config); err != nil {
		t.Fatalf("open: %v", err)
	}
	d, err := lookupDrive(config.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := d.health(context.Background()); err != nil {
		t.Fatalf("health: %v", err)
	}
	closeDrive(config.ID)
}

// Our own client's connections close with the drive. rclone's client can't be reached from
// here, so one idle connection per open lasts until its 60-second idle timeout.
func TestWebDAVOpenAndCloseLeaveNothingBehind(t *testing.T) {
	config := driveConfig{Kind: "webdav", URL: startWebDAV(t, t.TempDir())}
	expectNoGrowth(t, 75*time.Second, func(round int) { openAndClose(t, config, "webdav", round) })
}

func TestSFTPOpenAndCloseLeaveNothingBehind(t *testing.T) {
	config := startSFTP(t, t.TempDir())
	expectNoGrowth(t, 10*time.Second, func(round int) { openAndClose(t, config, "sftp", round) })
}

func TestFailedOpensLeaveNothingBehind(t *testing.T) {
	refused := startSFTP(t, t.TempDir())
	refused.Password = "wrong"
	unreachable := driveConfig{Kind: "webdav", URL: "http://127.0.0.1:1/cloudmount-test"}
	expectNoGrowth(t, 10*time.Second, func(round int) {
		for _, config := range []driveConfig{refused, unreachable} {
			config.ID = fmt.Sprintf("%s-%d", driveID(t), round)
			if _, err := openDrive(context.Background(), config); err == nil {
				t.Fatal("a failing open succeeded")
			}
		}
	})
}
