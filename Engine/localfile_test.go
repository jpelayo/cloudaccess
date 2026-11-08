// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
)

// A package is a folder that Finder shows as one file. Sending one as a file reads as an error
// partway through a PUT, and that used to come back as the server being unreachable.
func TestOnlyAPlainFileIsEverSent(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		ctx := context.Background()
		var counter atomic.Int64
		folder := filepath.Join(t.TempDir(), "comparativa.numbers")
		if err := os.Mkdir(folder, 0o700); err != nil {
			t.Fatal(err)
		}
		target := writeLocal(t, []byte("the real file"))
		link := filepath.Join(t.TempDir(), "link.txt")
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		for _, source := range []string{folder, link} {
			if _, err := d.stageUpload(ctx, source, &counter); classify(err).Kind != "notAPlainFile" {
				t.Fatalf("%s: got %v", source, err)
			}
		}
		if sent := counter.Load(); sent != 0 {
			t.Fatalf("%d bytes were read from something that isn't a plain file", sent)
		}
	})
}

func TestAFileThatCantBeReadIsntTheServersFault(t *testing.T) {
	onBothServers(t, func(t *testing.T, d *drive, _ string) {
		var counter atomic.Int64
		source := writeLocal(t, []byte("private"))
		if err := os.Chmod(source, 0); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(source, 0o600)
		_, err := d.stageUpload(context.Background(), source, &counter)
		if got := classify(err).Kind; got != "unreadableHere" {
			t.Fatalf("got %q from %v", got, err)
		}
	})
}

// The shape of the real failure: rclone's words around Go's request error around the read.
func TestAReadFailingDuringAnUploadSaysSo(t *testing.T) {
	read := localReadError{&os.PathError{Op: "read", Path: "/private/copy", Err: syscall.EISDIR}}
	failed := fmt.Errorf("unchunked simple update failed: %w",
		&url.Error{Op: "Put", URL: "https://example.invalid/staged", Err: read})

	result := classify(failed)

	if result.Kind != "unreadableHere" {
		t.Fatalf("got %q", result.Kind)
	}
	if result.Message != "is a directory" {
		t.Fatalf("the reason should be alone, with no paths: %q", result.Message)
	}
}
