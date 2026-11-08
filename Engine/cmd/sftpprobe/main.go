// Apache 2 license - developer@infinitecontext.com

// Command sftpprobe measures whether an SFTP server does what saves depend on: the atomic rename
// extension, and exactly one winner when two clients race to make a folder or move one.
//
// It reads the server from CM_TEST_WEBDAV_URL's host, and works inside a new folder in
// cloudmount-test, removing only what it made. Tools/probe-sftp.sh runs it.
package main

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path"
	"strconv"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

const (
	testFolder = "cloudmount-test"
	port       = 23
	races      = 100
)

func connect(host, user, password string, seen *string) (*ssh.Client, *sftp.Client, error) {
	config := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{ssh.Password(password)},
		// A throwaway test login: the key is shown, not pinned.
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			*seen = ssh.FingerprintSHA256(key)
			return nil
		},
		Timeout: 15 * time.Second,
	}
	address := net.JoinHostPort(host, strconv.Itoa(port))
	connection, err := ssh.Dial("tcp", address, config)
	if err != nil {
		return nil, nil, err
	}
	client, err := sftp.NewClient(connection)
	if err != nil {
		connection.Close()
		return nil, nil, err
	}
	return connection, client, nil
}

// race runs both actions at once, and reports how many succeeded.
func race(first, second func() error) int {
	var group sync.WaitGroup
	results := make([]error, 2)
	for index, action := range []func() error{first, second} {
		group.Add(1)
		go func() {
			defer group.Done()
			results[index] = action()
		}()
	}
	group.Wait()
	winners := 0
	for _, err := range results {
		if err == nil {
			winners++
		}
	}
	return winners
}

func report(name string, counts map[int]int) {
	fmt.Printf("%-24s one winner %d, none %d, both %d\n", name, counts[1], counts[0], counts[2])
}

func run() error {
	address, err := url.Parse(os.Getenv("CM_TEST_WEBDAV_URL"))
	if err != nil || address.Hostname() == "" {
		return errors.New("CM_TEST_WEBDAV_URL isn't set")
	}
	user, password := os.Getenv("CM_TEST_WEBDAV_USER"), os.Getenv("CM_TEST_WEBDAV_PASSWORD")

	var fingerprint string
	firstSSH, first, err := connect(address.Hostname(), user, password, &fingerprint)
	if err != nil {
		return fmt.Errorf("connecting on port %d: %w", port, err)
	}
	defer firstSSH.Close()
	defer first.Close()
	secondSSH, second, err := connect(address.Hostname(), user, password, &fingerprint)
	if err != nil {
		return fmt.Errorf("second connection: %w", err)
	}
	defer secondSSH.Close()
	defer second.Close()

	fmt.Printf("Server: %s\nHost key: %s\n", firstSSH.ServerVersion(), fingerprint)
	_, hasRename := first.HasExtension("posix-rename@openssh.com")
	fmt.Printf("posix-rename@openssh.com: %v\n", hasRename)

	if info, err := first.Stat(testFolder); err != nil || !info.IsDir() {
		return fmt.Errorf("no %s folder on this server", testFolder)
	}
	base := path.Join(testFolder, ".cm-probe-"+uuid.NewString())
	if err := first.Mkdir(base); err != nil {
		return fmt.Errorf("making the probe folder: %w", err)
	}

	made := map[int]int{}
	for run := 0; run < races; run++ {
		target := path.Join(base, fmt.Sprintf("claim-%d", run))
		made[race(
			func() error { return first.Mkdir(target) },
			func() error { return second.Mkdir(target) },
		)]++
		_ = first.RemoveDirectory(target)
	}
	report("mkdir race", made)

	if hasRename {
		moved := map[int]int{}
		for run := 0; run < races; run++ {
			source := path.Join(base, fmt.Sprintf("source-%d", run))
			left, right := source+"-a", source+"-b"
			if err := first.Mkdir(source); err != nil {
				return fmt.Errorf("making a source folder: %w", err)
			}
			moved[race(
				func() error { return first.PosixRename(source, left) },
				func() error { return second.PosixRename(source, right) },
			)]++
			for _, leftover := range []string{source, left, right} {
				_ = first.RemoveDirectory(leftover)
			}
		}
		report("move of one source race", moved)
	}

	if err := first.RemoveDirectory(base); err != nil {
		return fmt.Errorf("removing the probe folder: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "probe failed:", err)
		os.Exit(1)
	}
}
