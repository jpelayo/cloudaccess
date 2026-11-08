// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

const sftpTestPassword = "test-password"

// startSFTP serves a folder over a real SSH connection and returns how to reach it.
func startSFTP(t *testing.T, folder string) driveConfig {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{
		PasswordCallback: func(_ ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
			if string(password) != sftpTestPassword {
				return nil, errors.New("wrong password")
			}
			return nil, nil
		},
	}
	config.AddHostKey(signer)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go serveSFTP(connection, config, folder)
		}
	}()

	address := listener.Addr().(*net.TCPAddr)
	return driveConfig{
		Kind: "sftp", Host: "127.0.0.1", Port: address.Port, User: "tester",
		Password: sftpTestPassword, RootPath: folder,
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))),
	}
}

func serveSFTP(connection net.Conn, config *ssh.ServerConfig, folder string) {
	_, channels, requests, err := ssh.NewServerConn(connection, config)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(requests)
	for incoming := range channels {
		if incoming.ChannelType() != "session" {
			_ = incoming.Reject(ssh.UnknownChannelType, "sessions only")
			continue
		}
		channel, channelRequests, err := incoming.Accept()
		if err != nil {
			return
		}
		go func() {
			for request := range channelRequests {
				isSFTP := request.Type == "subsystem" && len(request.Payload) > 4 &&
					string(request.Payload[4:]) == "sftp"
				_ = request.Reply(isSFTP, nil)
			}
		}()
		go func() {
			defer channel.Close()
			server, err := sftp.NewServer(channel, sftp.WithServerWorkingDirectory(folder))
			if err == nil {
				_ = server.Serve()
			}
		}()
	}
}

// commitTests holds every commit test, so the same promises are checked on both protocols.
var commitTests = map[string]func(*testing.T){
	"SaveCreatesAndReplaces":      TestSaveCreatesAndReplacesFromTheBaseVersion,
	"APeersSaveIsNeverOverwriten": TestAPeersSaveIsNeverOverwritten,
	"ANewFileOnATakenName":        TestANewFileOnATakenNameBecomesAConflictCopy,
	"AnEditOfADeletedFile":        TestAnEditOfAFileAPeerDeletedIsPutBack,
	"SimultaneousSaves":           TestSimultaneousSavesKeepBothVersions,
	"AnAbandonedClaim":            TestAnAbandonedClaimIsTakenOver,
	"AFreshClaim":                 TestAFreshClaimBlocksAndReportsBusy,
	"NoClaimLeftBehind":           TestNoClaimOrStagingFileIsLeftBehind,
	"MoveRefusesToReplace":        TestMoveRefusesToReplaceAnything,
	"DeleteGoesToTrash":           TestDeleteGoesToTrashAndCanBeRecovered,
	"DeletingANewerVersion":       TestDeletingAPeersNewerVersionIsRefused,
	"DeletingAFolder":             TestDeletingAFolderKeepsEverythingInsideIt,
	"ASaveStandsAside":            TestASaveStandsAsideForAFolderOperation,
	"AFolderMoveWaits":            TestAFolderMoveWaitsForALiveSave,
	"AChildSaveAgainstAMove":      TestAChildSaveAgainstAFolderMoveLosesNothing,
	"AChildSaveAgainstATrash":     TestAChildSaveAgainstAFolderTrashLosesNothing,
}

func TestCommitLayerOverSFTP(t *testing.T) {
	testServer = startSFTP
	defer func() { testServer = nil }()
	for name, test := range commitTests {
		t.Run(name, test)
	}
}

func openSFTP(t *testing.T, config driveConfig) *drive {
	t.Helper()
	config.ID = driveID(t)
	config.DeviceID = "device-a"
	if _, err := openDrive(context.Background(), config); err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { closeDrive(config.ID) })
	d, err := lookupDrive(config.ID)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// A plain drive has no crypt nonce or ETag, so this is the weakest case.
func TestSFTPSavesAnEditOnAPlainDrive(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	var counter atomic.Int64

	first, err := d.save(ctx, writeLocal(t, []byte("first")), "note.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.save(ctx, writeLocal(t, []byte("second, longer")), "note.txt", first.Item.Version, &counter); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(folder, "note.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "second, longer" {
		t.Errorf("content = %q", content)
	}
}

// A reader must never find the file missing while a save replaces it.
func TestSFTPReplaceNeverLeavesTheFileAbsent(t *testing.T) {
	ctx := context.Background()
	folder := t.TempDir()
	d := openSFTP(t, startSFTP(t, folder))
	var counter atomic.Int64
	saved, err := d.save(ctx, writeLocal(t, []byte("v0")), "watched.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})
	var missing atomic.Int64
	var watcher sync.WaitGroup
	watcher.Add(1)
	go func() {
		defer watcher.Done()
		for {
			select {
			case <-done:
				return
			default:
				if _, err := os.Stat(filepath.Join(folder, "watched.txt")); err != nil {
					missing.Add(1)
				}
			}
		}
	}()

	for version := range 20 {
		content := strings.Repeat("x", version+3)
		result, err := d.save(ctx, writeLocal(t, []byte(content)), "watched.txt", saved.Item.Version, &counter)
		if err != nil {
			t.Fatal(err)
		}
		if result.ConflictPath != "" {
			t.Fatalf("own edit became a conflict: %+v", result)
		}
		saved = result
	}
	close(done)
	watcher.Wait()
	if missing.Load() != 0 {
		t.Errorf("the file was absent %d times", missing.Load())
	}
}

func TestSFTPRefusesAChangedHostKey(t *testing.T) {
	config := startSFTP(t, t.TempDir())
	other := startSFTP(t, t.TempDir())
	config.HostKey = other.HostKey
	config.ID = driveID(t)

	_, err := openDrive(context.Background(), config)
	if !errors.Is(err, errHostKeyChanged) {
		t.Fatalf("err = %v", err)
	}
	if kind := classify(err).Kind; kind != "hostKeyChanged" {
		t.Errorf("kind = %q", kind)
	}
}

func TestSFTPRefusesAnUnconfirmedServer(t *testing.T) {
	config := startSFTP(t, t.TempDir())
	config.HostKey = ""
	config.ID = driveID(t)

	if _, err := openDrive(context.Background(), config); !errors.Is(err, errHostKeyUnknown) {
		t.Fatalf("err = %v", err)
	}
}

func TestSFTPHostKeyCanBeReadBeforeSigningIn(t *testing.T) {
	config := startSFTP(t, t.TempDir())

	info, err := probeHostKey(context.Background(), config.Host, config.Port)
	if err != nil {
		t.Fatal(err)
	}
	if info.Key != config.HostKey {
		t.Errorf("key = %q, want %q", info.Key, config.HostKey)
	}
	if !strings.HasPrefix(info.Fingerprint, "SHA256:") {
		t.Errorf("fingerprint = %q", info.Fingerprint)
	}
}

func TestSFTPWrongPasswordIsAConnectionProblem(t *testing.T) {
	config := startSFTP(t, t.TempDir())
	config.Password = "wrong"
	config.ID = driveID(t)

	_, err := openDrive(context.Background(), config)
	if err == nil {
		t.Fatal("a wrong password was accepted")
	}
	if kind := classify(err).Kind; kind != "unauthorized" {
		t.Errorf("kind = %q, message = %v", kind, err)
	}
}

func TestTrimmingMemoryLeavesDrivesWorking(t *testing.T) {
	ctx := context.Background()
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	var counter atomic.Int64
	first, err := d.save(ctx, writeLocal(t, []byte("before")), "kept.txt", "", &counter)
	if err != nil {
		t.Fatal(err)
	}

	trimMemory()

	if _, err := d.save(ctx, writeLocal(t, []byte("after trim")), "kept.txt", first.Item.Version, &counter); err != nil {
		t.Fatalf("save after trimming: %v", err)
	}
	if got := read(t, d, "kept.txt"); got != "after trim" {
		t.Errorf("content = %q", got)
	}
}

// silentSSH accepts SSH and a session, then never answers the SFTP handshake.
func silentSSH(t *testing.T) driveConfig {
	t.Helper()
	config := startSFTP(t, t.TempDir())
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	server := &ssh.ServerConfig{NoClientAuth: true}
	server.AddHostKey(signer)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				_, channels, requests, err := ssh.NewServerConn(connection, server)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(requests)
				for incoming := range channels {
					channel, channelRequests, err := incoming.Accept()
					if err != nil {
						return
					}
					defer channel.Close()
					go func() {
						for request := range channelRequests {
							_ = request.Reply(true, nil)
						}
					}()
				}
			}()
		}
	}()
	config.Port = listener.Addr().(*net.TCPAddr).Port
	config.HostKey = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
	return config
}

func TestASilentServerCantHoldACancelledConnect(t *testing.T) {
	secure, err := newSFTPServer(silentSSH(t))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	started := time.Now()
	_, err = secure.connect(ctx)
	if err == nil {
		t.Fatal("connected to a silent server")
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Errorf("took %v to give up", elapsed)
	}
}

func TestACancelledCallNeverStarts(t *testing.T) {
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := d.server.createExclusive(ctx, ".cloudmount/claims/cancelled"); !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v", err)
	}
}

func TestSFTPReconnectsAfterADroppedConnection(t *testing.T) {
	ctx := context.Background()
	d := openSFTP(t, startSFTP(t, t.TempDir()))
	secure := d.server.(*sftpServer)
	var counter atomic.Int64
	if _, err := d.save(ctx, writeLocal(t, []byte("x")), "kept.txt", "", &counter); err != nil {
		t.Fatal(err)
	}

	// As after sleep: the connection is dead, but nothing has noticed yet.
	secure.mu.Lock()
	secure.session.Close()
	secure.mu.Unlock()

	items, err := d.list(ctx, "")
	if err != nil {
		t.Fatalf("list after a dropped connection: %v", err)
	}
	if len(items) != 1 || items[0].Path != "kept.txt" {
		t.Errorf("items = %+v", items)
	}
}
