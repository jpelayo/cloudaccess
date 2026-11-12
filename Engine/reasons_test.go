// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"syscall"
	"testing"

	"github.com/rclone/rclone/backend/webdav/api"
)

func dialFailure(errno error) error {
	return &url.Error{Op: "Get", URL: "https://example.com", Err: &net.OpError{
		Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", errno),
	}}
}

// Each way of failing to reach a server keeps its own reason, so the apps never have to guess.
func TestUnreachableSaysWhy(t *testing.T) {
	refused := dialFailure(syscall.ECONNREFUSED)
	for _, test := range []struct {
		name   string
		err    error
		reason string
	}{
		{"name not found", &url.Error{Op: "Get", Err: &net.OpError{Op: "dial", Err: &net.DNSError{Name: "nas.example", IsNotFound: true}}}, "nameNotFound"},
		{"lookup timed out", &net.OpError{Op: "dial", Err: &net.DNSError{Name: "nas.example", IsTimeout: true}}, "nameLookupFailed"},
		{"refused", refused, "refused"},
		{"host down", dialFailure(syscall.EHOSTDOWN), "hostDown"},
		{"no route to host", dialFailure(syscall.EHOSTUNREACH), "hostUnreachable"},
		{"no network", dialFailure(syscall.ENETUNREACH), "networkUnreachable"},
		{"dial timed out", &net.OpError{Op: "dial", Err: os.ErrDeadlineExceeded}, "timedOut"},
		{"deadline", context.DeadlineExceeded, "timedOut"},
		{"expired certificate", &url.Error{Op: "Get", Err: &tls.CertificateVerificationError{Err: x509.CertificateInvalidError{Reason: x509.Expired}}}, "certificateExpired"},
		{"untrusted certificate", &url.Error{Op: "Get", Err: &tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}}, "certificateUntrusted"},
		{"certificate for another name", &url.Error{Op: "Get", Err: &tls.CertificateVerificationError{Err: x509.HostnameError{Host: "nas.example"}}}, "certificateWrongName"},
		{"macOS certificate text", &url.Error{Op: "Get", Err: errors.New(`x509: "nas" certificate is not trusted`)}, "certificateUntrusted"},
		{"not TLS", &url.Error{Op: "Get", Err: tls.RecordHeaderError{Msg: "first record does not look like a TLS handshake"}}, "notTLS"},
		{"reset", dialFailure(syscall.ECONNRESET), "connectionReset"},
		{"closed before the handshake", fmt.Errorf("ssh: handshake failed: %w", io.EOF), "connectionReset"},
		{"other handshake failure", errors.New("ssh: handshake failed: ssh: no common algorithm for key exchange"), "sshHandshake"},
		{"lost session", errServerGone, "connectionLost"},
		{"too slow", fmt.Errorf("%w: %v", errTooSlow, os.ErrDeadlineExceeded), "tooSlow"},
		{"not WebDAV", errBadReply, "notWebDAV"},
		{"server gave up waiting", &api.Error{StatusCode: 408}, "timedOut"},
		{"a lost answer keeps its cause", withCause(fmt.Errorf("%w: %v", errResultUnknown, refused), refused), "refused"},
		{"a lost session keeps its cause", withCause(fmt.Errorf("%w: %v", errServerGone, io.EOF), io.EOF), "connectionReset"},
		{"nothing says", errResultUnknown, "unknown"},
	} {
		t.Run(test.name, func(t *testing.T) {
			result := classify(test.err)
			if result.Kind != "unreachable" {
				t.Fatalf("kind = %q, want unreachable (%v)", result.Kind, test.err)
			}
			if result.Reason != test.reason {
				t.Errorf("reason = %q, want %q (%v)", result.Reason, test.reason, test.err)
			}
		})
	}
}

// A kept cause is for the reason only. It can never change a kind, so what the apps and macOS are
// told stays exactly as it was.
func TestAKeptCauseNeverChangesTheKind(t *testing.T) {
	for _, cause := range []error{fs.ErrNotExist, fs.ErrPermission, errNameTaken, errWrongPassword, context.Canceled} {
		for _, wrapper := range []error{errResultUnknown, errServerGone} {
			err := withCause(fmt.Errorf("%w: %v", wrapper, cause), cause)
			if kind := classify(err).Kind; kind != "unreachable" {
				t.Errorf("%v around %v: kind = %q, want unreachable", wrapper, cause, kind)
			}
			if err.Error() != fmt.Errorf("%w: %v", wrapper, cause).Error() {
				t.Errorf("the message changed: %q", err.Error())
			}
		}
	}
	if result := classify(errWrongPassword); result.Reason != "" {
		t.Errorf("only an unreachable server has a reason, got %q", result.Reason)
	}
}

func openFailure(t *testing.T, id, address string) errorResult {
	t.Helper()
	t.Cleanup(func() { closeDrive(id) })
	_, err := openDrive(context.Background(), driveConfig{
		ID: id, Kind: "webdav", URL: address, Encrypted: true, VaultPassword: interopPassword,
	})
	if err == nil {
		t.Fatal("expected an error")
	}
	return classify(err)
}

func TestARefusedPortSaysSo(t *testing.T) {
	if result := openFailure(t, "refused", "http://127.0.0.1:1"); result.Reason != "refused" {
		t.Errorf("kind %q, reason %q: %s", result.Kind, result.Reason, result.Message)
	}
}

func TestAnUntrustedCertificateSaysSo(t *testing.T) {
	server := httptest.NewTLSServer(http.NotFoundHandler())
	defer server.Close()
	result := openFailure(t, "untrusted", server.URL)
	if result.Kind != "unreachable" || !strings.HasPrefix(result.Reason, "certificate") {
		t.Errorf("kind %q, reason %q: %s", result.Kind, result.Reason, result.Message)
	}
}

func TestPlainHTTPOnAnHTTPSAddressSaysItIsntTLS(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	defer server.Close()
	address := strings.Replace(server.URL, "http://", "https://", 1)
	if result := openFailure(t, "not-tls", address); result.Reason != "notTLS" {
		t.Errorf("kind %q, reason %q: %s", result.Kind, result.Reason, result.Message)
	}
}
