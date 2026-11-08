// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/rclone/rclone/backend/webdav/api"
	rclonefs "github.com/rclone/rclone/fs"
)

// activeCall is a running engine call that can be cancelled or polled.
type activeCall struct {
	ctx    context.Context
	cancel context.CancelFunc
	bytes  atomic.Int64
}

var calls sync.Map // call ID to *activeCall

// errorResult is the machine-readable form of a failure. Swift maps Kind to
// RemoteError, which decides whether it affects one item or the connection.
type errorResult struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Status  int    `json:"status,omitempty"`
}

type callResult struct {
	Value any          `json:"value,omitempty"`
	Error *errorResult `json:"error,omitempty"`
}

func classify(err error) errorResult {
	result := errorResult{Kind: "other", Message: err.Error()}

	// First, because it's wrapped in a failed request, and that isn't what happened.
	var unreadable localReadError
	if errors.As(err, &unreadable) {
		return errorResult{Kind: "unreadableHere", Message: unreadable.reason()}
	}

	for _, known := range []struct {
		err  error
		kind string
	}{
		{errClaimBusy, "locked"},
		{errClaimLost, "locked"},
		{errResultUnknown, "unreachable"},
		{errBadReply, "unreachable"},
		{errTooSlow, "unreachable"},
		{errFolderTooSlow, "tooSlow"},
		{errFolderTooBig, "tooManyItems"},
		{errDigestOnly, "unsupportedServer"},
		{errReadOnly, "readOnly"},
		{errInsecureRefused, "unsupportedServer"},
		{errBadAddress, "unsupportedServer"},
		{errNameTooLong, "nameTooLong"},
		{errNotAPlainFile, "notAPlainFile"},
		{errNotInTrash, "notFound"},
		{errVaultOnPlainDrive, "vaultEncrypted"},
		{errHostKeyUnknown, "hostKeyUnknown"},
		{errHostKeyChanged, "hostKeyChanged"},
		{errNoAtomicReplace, "unsupportedServer"},
		{errServerGone, "unreachable"},
		{errPeerChanged, "versionMismatch"},
		{errNameTaken, "alreadyExists"},
		{errWrongPassword, "wrongPassword"},
		{errVaultMissing, "vaultMissing"},
		{errVaultNotCreated, "vaultNotCreated"},
		{errVaultMismatch, "vaultMismatch"},
		{errVaultRollback, "vaultRollback"},
		{errVaultRetired, "vaultRetired"},
		{errVaultUnsupported, "vaultUnsupported"},
		{errVaultMalformed, "vaultMalformed"},
	} {
		if errors.Is(err, known.err) {
			result.Kind = known.kind
			return result
		}
	}

	var davError *api.Error
	if errors.As(err, &davError) {
		result.Status = davError.StatusCode
		switch {
		case davError.StatusCode == 401:
			result.Kind = "unauthorized"
		case davError.StatusCode == 403:
			result.Kind = "forbidden"
		case davError.StatusCode == 404 || davError.StatusCode == 410:
			result.Kind = "notFound"
		case davError.StatusCode == 408:
			// The server gave up waiting for the request, which trying again can fix.
			result.Kind = "unreachable"
		case davError.StatusCode == 409:
			result.Kind = "parentMissing"
		case davError.StatusCode == 412:
			result.Kind = "versionMismatch"
		case davError.StatusCode == 413:
			result.Kind = "tooLarge"
		case davError.StatusCode == 429:
			// The server wants fewer requests for a while. Later works, so this isn't one file's fault.
			result.Kind = "server"
		case davError.StatusCode == 423:
			result.Kind = "locked"
		case davError.StatusCode == 507:
			result.Kind = "insufficientStorage"
		case davError.StatusCode >= 500:
			result.Kind = "server"
		}
		return result
	}

	// ssh reports these as plain text, with no error type to match.
	if message := err.Error(); strings.Contains(message, "ssh: unable to authenticate") {
		result.Kind = "unauthorized"
		return result
	} else if strings.Contains(message, "ssh: handshake failed") {
		result.Kind = "unreachable"
		return result
	}

	var netError net.Error
	var urlError *url.Error
	switch {
	case errors.Is(err, context.Canceled):
		result.Kind = "cancelled"
	case errors.Is(err, rclonefs.ErrorObjectNotFound),
		errors.Is(err, rclonefs.ErrorDirNotFound),
		errors.Is(err, fs.ErrNotExist):
		result.Kind = "notFound"
	case errors.Is(err, rclonefs.ErrorDirExists), errors.Is(err, fs.ErrExist):
		result.Kind = "alreadyExists"
	case errors.Is(err, fs.ErrPermission):
		result.Kind = "forbidden"
	case errors.As(err, &netError), errors.As(err, &urlError):
		result.Kind = "unreachable"
	}
	return result
}

// registerCall makes a call cancellable before it's dispatched, so a cancel can't
// arrive too early and be forgotten. Every registered call must then be run.
func registerCall(callID int64) {
	ctx, cancel := context.WithCancel(context.Background())
	calls.Store(callID, &activeCall{ctx: ctx, cancel: cancel})
}

// guarded turns a panic into an error. A panic crossing the C boundary ends the whole
// process, and one failed call must never take every drive down with it.
func guarded(work func() (any, error)) (value any, err error) {
	defer func() {
		if failure := recover(); failure != nil {
			value, err = nil, fmt.Errorf("the engine failed: %v", failure)
		}
	}()
	return work()
}

// runCall executes one method and returns its JSON result. The call ID lets
// another thread cancel it or read its progress while it runs.
func runCall(callID int64, method string, arguments []byte) []byte {
	// One atomic step, so a call that finishes at the same moment can't leave this empty.
	ctx, cancel := context.WithCancel(context.Background())
	loaded, registered := calls.LoadOrStore(callID, &activeCall{ctx: ctx, cancel: cancel})
	if registered {
		cancel()
	}
	call := loaded.(*activeCall)
	defer func() {
		calls.Delete(callID)
		call.cancel()
	}()

	var result callResult
	value, err := guarded(func() (any, error) {
		return dispatch(call.ctx, method, arguments, &call.bytes)
	})
	if err != nil {
		info := classify(err)
		result.Error = &info
	} else {
		result.Value = value
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return []byte(`{"error":{"kind":"other","message":"could not encode the result"}}`)
	}
	return encoded
}

func cancelCall(callID int64) {
	if call, ok := calls.Load(callID); ok {
		call.(*activeCall).cancel()
	}
}

func callProgress(callID int64) int64 {
	if call, ok := calls.Load(callID); ok {
		return call.(*activeCall).bytes.Load()
	}
	return -1
}
