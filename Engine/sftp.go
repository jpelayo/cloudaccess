// Apache 2 license - developer@infinitecontext.com

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

// sftpServer makes the few SFTP requests rclone's backend doesn't offer: a replace in one
// step, which its move can't do because it removes the destination first, and folder
// creation that says who won. File transfers still go through rclone.
type sftpServer struct {
	address string
	root    string
	config  *ssh.ClientConfig

	mu      sync.Mutex
	session *ssh.Client
	client  *sftp.Client
}

const (
	sftpConnectLimit = 15 * time.Second
	sftpRequestLimit = 30 * time.Second
	// Replacing a file in one step needs this OpenSSH extension. Plain SFTP rename refuses
	// an existing destination, and removing it first would leave a moment with no file.
	posixRename = "posix-rename@openssh.com"
)

var (
	errHostKeyUnknown  = errors.New("this server's identity hasn't been confirmed")
	errHostKeyChanged  = errors.New("this server's identity has changed")
	errNoAtomicReplace = errors.New("this server can't replace a file in one step, so saves wouldn't be safe")
	errServerGone      = errors.New("the connection to the server was lost")
)

func sftpAddress(host string, port int) string {
	if port == 0 {
		port = 22
	}
	return net.JoinHostPort(host, strconv.Itoa(port))
}

// pinnedKey parses a host key in authorized_keys form, as hostKeyInfo reports it.
func pinnedKey(pin string) (ssh.PublicKey, error) {
	key, _, _, _, err := ssh.ParseAuthorizedKey([]byte(pin))
	if err != nil {
		return nil, fmt.Errorf("%w: the saved key is unreadable", errHostKeyChanged)
	}
	return key, nil
}

// newSFTPServer prepares a connection to a server that must present exactly the pinned key.
func newSFTPServer(c driveConfig) (*sftpServer, error) {
	if c.HostKey == "" {
		return nil, errHostKeyUnknown
	}
	wanted, err := pinnedKey(c.HostKey)
	if err != nil {
		return nil, err
	}
	methods, err := sftpAuthMethods(c)
	if err != nil {
		return nil, err
	}
	algorithms := []string{wanted.Type()}
	if wanted.Type() == ssh.KeyAlgoRSA {
		algorithms = []string{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSA}
	}
	return &sftpServer{
		address: sftpAddress(c.Host, c.Port),
		root:    c.RootPath,
		config: &ssh.ClientConfig{
			User:              c.User,
			Auth:              methods,
			HostKeyAlgorithms: algorithms,
			Timeout:           sftpConnectLimit,
			HostKeyCallback: func(_ string, _ net.Addr, offered ssh.PublicKey) error {
				if !bytes.Equal(offered.Marshal(), wanted.Marshal()) {
					return errHostKeyChanged
				}
				return nil
			},
		},
	}, nil
}

func sftpAuthMethods(c driveConfig) ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod
	if c.KeyPEM != "" {
		var signer ssh.Signer
		var err error
		if c.KeyPassphrase != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(c.KeyPEM), []byte(c.KeyPassphrase))
		} else {
			signer, err = ssh.ParsePrivateKey([]byte(c.KeyPEM))
		}
		if err != nil {
			return nil, fmt.Errorf("unreadable private key: %w", err)
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if c.Password != "" {
		methods = append(methods, ssh.Password(c.Password))
	}
	return methods, nil
}

// hostKeyInfo is what a person confirms before a server is trusted.
type hostKeyInfo struct {
	Key         string `json:"key"`
	Fingerprint string `json:"fingerprint"`
}

// keyFingerprint describes a key already saved, for comparing with what a server offers now.
func keyFingerprint(pin string) (hostKeyInfo, error) {
	key, err := pinnedKey(pin)
	if err != nil {
		return hostKeyInfo{}, err
	}
	return hostKeyInfo{Key: pin, Fingerprint: ssh.FingerprintSHA256(key)}, nil
}

var errStopHandshake = errors.New("stopped after reading the host key")

// probeHostKey reads a server's key without signing in, so it can be shown for confirmation.
func probeHostKey(ctx context.Context, host string, port int) (hostKeyInfo, error) {
	address := sftpAddress(host, port)
	dialer := net.Dialer{Timeout: sftpConnectLimit}
	connection, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return hostKeyInfo{}, err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(sftpConnectLimit))

	var offered ssh.PublicKey
	_, _, _, err = ssh.NewClientConn(connection, address, &ssh.ClientConfig{
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			offered = key
			return errStopHandshake
		},
	})
	if offered == nil {
		return hostKeyInfo{}, err
	}
	return hostKeyInfo{
		Key:         strings.TrimSpace(string(ssh.MarshalAuthorizedKey(offered))),
		Fingerprint: ssh.FingerprintSHA256(offered),
	}, nil
}

func (s *sftpServer) connect(ctx context.Context) (*sftp.Client, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client != nil {
		return s.client, nil
	}

	dialer := net.Dialer{Timeout: sftpConnectLimit}
	connection, err := dialer.DialContext(ctx, "tcp", s.address)
	if err != nil {
		return nil, err
	}
	// The deadline stays until the SFTP handshake finishes, and a cancel closes the socket, so
	// a server that accepts SSH and then goes silent can't hold this lock.
	_ = connection.SetDeadline(time.Now().Add(sftpConnectLimit))
	stop := context.AfterFunc(ctx, func() { connection.Close() })
	defer stop()

	conn, channels, requests, err := ssh.NewClientConn(connection, s.address, s.config)
	if err != nil {
		connection.Close()
		return nil, err
	}
	session := ssh.NewClient(conn, channels, requests)
	client, err := sftp.NewClient(session)
	if err != nil {
		session.Close()
		return nil, err
	}
	if _, ok := client.HasExtension(posixRename); !ok {
		session.Close()
		client.Close()
		return nil, errNoAtomicReplace
	}
	_ = connection.SetDeadline(time.Time{})
	s.session, s.client = session, client
	return client, nil
}

// disconnect closes the SSH transport first. sftp.Client.Close waits for its reader, and only
// a dead transport guarantees that reader ends if the server has stopped answering.
func (s *sftpServer) disconnect(failed *sftp.Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client == nil || (failed != nil && s.client != failed) {
		return
	}
	s.session.Close()
	s.client.Close()
	s.client, s.session = nil, nil
}

func isConnectionLost(err error) bool {
	return errors.Is(err, sftp.ErrSSHFxConnectionLost) || errors.Is(err, io.EOF) ||
		errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, net.ErrClosed)
}

// sftpRequest runs one request and returns its result over a channel, so an abandoned request
// can't touch anything after its caller has gone. SFTP requests can't be cancelled: a cancel
// lets this one finish alone, because other calls share the connection, and only a request
// that outlasts the limit drops it. A connection can die while idle, for example during
// sleep, so a repeatable request gets one more try on a new connection.
func sftpRequest[Result any](
	ctx context.Context, s *sftpServer, repeatable bool, request func(*sftp.Client) (Result, error),
) (Result, error) {
	type outcome struct {
		value Result
		err   error
	}
	var none Result
	for attempt := 1; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return none, err
		}
		client, err := s.connect(ctx)
		if err != nil {
			return none, err
		}
		done := make(chan outcome, 1)
		go func() {
			// The guard at the C boundary can't see this goroutine, and a panic here would end
			// the whole process.
			defer func() {
				if failure := recover(); failure != nil {
					done <- outcome{none, fmt.Errorf("the engine failed: %v", failure)}
				}
			}()
			value, err := request(client)
			done <- outcome{value, err}
		}()

		var result outcome
		select {
		case result = <-done:
		case <-ctx.Done():
			go func() {
				select {
				case <-done:
				case <-time.After(sftpRequestLimit):
					s.disconnect(client)
				}
			}()
			return none, ctx.Err()
		case <-time.After(sftpRequestLimit):
			s.disconnect(client)
			return none, errServerGone
		}
		if result.err == nil || !isConnectionLost(result.err) {
			return result.value, result.err
		}
		s.disconnect(client)
		if !repeatable || attempt == 2 {
			return none, fmt.Errorf("%w: %v", errServerGone, result.err)
		}
	}
}

// full joins a path to the drive's root. Cleaning it as if it were absolute first means that no
// path, however it got here, can climb out of the drive's folder.
func (s *sftpServer) full(rawPath string) string {
	inside := strings.TrimPrefix(path.Clean("/"+rawPath), "/")
	if joined := path.Join(s.root, inside); joined != "" {
		return joined
	}
	return "."
}

func (s *sftpServer) createExclusive(ctx context.Context, rawPath string) (bool, error) {
	target := s.full(rawPath)
	return sftpRequest(ctx, s, false, func(client *sftp.Client) (bool, error) {
		err := client.Mkdir(target)
		if err == nil {
			return true, nil
		}
		// OpenSSH reports an existing folder and a missing parent the same way, so look.
		if _, statErr := client.Lstat(target); statErr == nil {
			return false, nil
		}
		if parentErr := client.MkdirAll(path.Dir(target)); parentErr != nil {
			return false, parentErr
		}
		if err := client.Mkdir(target); err != nil {
			if _, statErr := client.Lstat(target); statErr == nil {
				return false, nil
			}
			return false, err
		}
		return true, nil
	})
}

func (s *sftpServer) ensureFolder(ctx context.Context, rawPath string) error {
	target := s.full(rawPath)
	_, err := sftpRequest(ctx, s, true, func(client *sftp.Client) (struct{}, error) {
		return struct{}{}, client.MkdirAll(target)
	})
	return err
}

func (s *sftpServer) remove(ctx context.Context, rawPath string, folder bool) error {
	_, err := s.removeFound(ctx, rawPath, folder)
	return err
}

func (s *sftpServer) removeFound(ctx context.Context, rawPath string, folder bool) (bool, error) {
	target := s.full(rawPath)
	_, err := sftpRequest(ctx, s, true, func(client *sftp.Client) (struct{}, error) {
		if folder {
			return struct{}{}, client.RemoveDirectory(target)
		}
		return struct{}{}, client.Remove(target)
	})
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

func (s *sftpServer) removeAll(ctx context.Context, rawPath string) error {
	entries, err := s.listRaw(ctx, rawPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		child := rawPath + "/" + entry.Name
		if entry.IsDirectory {
			err = s.removeAll(ctx, child)
		} else {
			err = s.remove(ctx, child, false)
		}
		if err != nil {
			return err
		}
	}
	return s.remove(ctx, rawPath, true)
}

func (s *sftpServer) moveRaw(ctx context.Context, from, to string, _, overwrite bool) error {
	source, destination := s.full(from), s.full(to)
	_, err := sftpRequest(ctx, s, false, func(client *sftp.Client) (struct{}, error) {
		if overwrite {
			return struct{}{}, client.PosixRename(source, destination)
		}
		return struct{}{}, client.Rename(source, destination)
	})
	return err
}

// keepCopy makes a hard link, which is instant at any size. The file that's about to be replaced
// goes on existing under the new name, because a rename only swaps which file the name points to.
func (s *sftpServer) keepCopy(ctx context.Context, from, to string, _ int64) error {
	source, destination := s.full(from), s.full(to)
	_, err := sftpRequest(ctx, s, false, func(client *sftp.Client) (struct{}, error) {
		return struct{}{}, client.Link(source, destination)
	})
	return err
}

// sftpEntry builds a raw entry. SFTP has no ETag and only reports whole seconds, so this
// version is weak: two same-size edits within one second look the same.
func sftpEntry(info os.FileInfo) rawEntry {
	entry := rawEntry{
		Name:        info.Name(),
		IsDirectory: info.IsDir(),
		Size:        info.Size(),
		Modified:    info.ModTime(),
	}
	if !entry.IsDirectory {
		entry.ETag = fmt.Sprintf("%d-%d", info.Size(), info.ModTime().Unix())
	}
	return entry
}

func (s *sftpServer) listRaw(ctx context.Context, rawPath string) ([]rawEntry, error) {
	target := s.full(rawPath)
	return sftpRequest(ctx, s, true, func(client *sftp.Client) ([]rawEntry, error) {
		infos, err := client.ReadDir(target)
		if err != nil {
			return nil, err
		}
		entries := make([]rawEntry, 0, len(infos))
		for _, info := range infos {
			// Symlinks and special files aren't synced in this version.
			if info.IsDir() || info.Mode().IsRegular() {
				entries = append(entries, sftpEntry(info))
			}
		}
		return entries, nil
	})
}

func (s *sftpServer) statRaw(ctx context.Context, rawPath string) (rawEntry, error) {
	target := s.full(rawPath)
	return sftpRequest(ctx, s, true, func(client *sftp.Client) (rawEntry, error) {
		info, err := client.Lstat(target)
		if err != nil {
			return rawEntry{}, err
		}
		entry := sftpEntry(info)
		entry.Name = path.Base(target)
		return entry, nil
	})
}

func (s *sftpServer) stampNewer(ctx context.Context, rawPath string, than time.Time) error {
	target := s.full(rawPath)
	stamp := than.Truncate(time.Second).Add(time.Second)
	_, err := sftpRequest(ctx, s, true, func(client *sftp.Client) (struct{}, error) {
		return struct{}{}, client.Chtimes(target, stamp, stamp)
	})
	return err
}
