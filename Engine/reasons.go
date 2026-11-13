// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"strings"
	"syscall"

	"github.com/rclone/rclone/backend/webdav/api"
)

// causedError keeps the error that led to a wrapper, only for unreachableReason. Unwrap gives the
// wrapper alone, so errors.Is and classifyKind see exactly what they saw before, and no inner
// error can change a kind.
type causedError struct {
	err   error
	cause error
}

func (c causedError) Error() string { return c.err.Error() }
func (c causedError) Unwrap() error { return c.err }

// withCause marks wrapped as having come from cause.
func withCause(wrapped, cause error) error {
	if cause == nil {
		return wrapped
	}
	return causedError{err: wrapped, cause: cause}
}

// unreachableReason says which part of reaching the server failed: the name, the route, the
// port, the certificate, or the connection once it was up. "unknown" when nothing says, so the
// apps say they can't tell rather than guess. The order matters: the most specific cause wins.
func unreachableReason(err error) string {
	var caused causedError
	if errors.As(err, &caused) {
		if reason := unreachableReason(caused.cause); reason != "unknown" {
			return reason
		}
	}

	var dnsError *net.DNSError
	var certificateInvalid x509.CertificateInvalidError
	var unknownAuthority x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var recordHeader tls.RecordHeaderError
	var davError *api.Error
	var netError net.Error
	switch {
	case errors.As(err, &dnsError):
		if dnsError.IsNotFound {
			return "nameNotFound"
		}
		return "nameLookupFailed"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "refused"
	case errors.Is(err, syscall.EHOSTDOWN):
		return "hostDown"
	case errors.Is(err, syscall.EHOSTUNREACH):
		return "hostUnreachable"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EADDRNOTAVAIL):
		return "networkUnreachable"
	case errors.As(err, &certificateInvalid):
		if certificateInvalid.Reason == x509.Expired {
			return "certificateExpired"
		}
		return "certificateUntrusted"
	case errors.As(err, &hostname):
		return "certificateWrongName"
	case errors.As(err, &unknownAuthority):
		return "certificateUntrusted"
	case errors.As(err, &recordHeader):
		return "notTLS"
	case errors.Is(err, errTooSlow):
		return "tooSlow"
	case errors.Is(err, errBadReply):
		return "notWebDAV"
	case errors.As(err, &davError) && davError.StatusCode == 408:
		return "timedOut"
	case errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.EPIPE):
		return "connectionReset"
	case errors.Is(err, errServerGone):
		return "connectionLost"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &netError) && netError.Timeout():
		return "timedOut"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		// The server closed the connection before answering.
		return "connectionReset"
	}
	// macOS's own certificate check can fail in ways Go only reports as text, and Go's HTTP
	// client swaps the TLS error for a sentence of its own when plain HTTP answers.
	message := err.Error()
	switch {
	case strings.Contains(message, "server gave HTTP response to HTTPS client"):
		return "notTLS"
	case strings.Contains(message, "x509:"):
		return "certificateUntrusted"
	case strings.Contains(message, "ssh: handshake failed"):
		return "sshHandshake"
	}
	return "unknown"
}
