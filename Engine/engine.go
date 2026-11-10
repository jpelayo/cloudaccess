// Apache 2 license - developer@infinitecontext.com

// Package main builds the CloudAccess engine: a thin C interface over rclone's
// WebDAV, SFTP and crypt backends, compiled with -buildmode=c-archive.
//
// Calls pass JSON metadata and file paths, never file bytes. CMCallBytes blocks, so
// callers run it on their own thread and use CMCancel and CMProgress from another.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"runtime/debug"
	"unsafe"

	_ "github.com/rclone/rclone/backend/crypt"
	_ "github.com/rclone/rclone/backend/sftp"
	_ "github.com/rclone/rclone/backend/webdav"
)

// CMInit prepares the engine. memoryLimitBytes caps the Go heap; 0 leaves it unset.
//
//export CMInit
func CMInit(memoryLimitBytes C.longlong) {
	if memoryLimitBytes > 0 {
		debug.SetMemoryLimit(int64(memoryLimitBytes))
	}
	configureRclone()
}

// CMInitLean prepares the engine for a process that iOS stops at a small size, such as the
// iPhone's Files extension. Call it once instead of CMInit. maxEntries is the largest folder
// it lists; a bigger one is refused whole.
//
//export CMInitLean
func CMInitLean(memoryLimitBytes C.longlong, maxEntries C.longlong) {
	useLean(int(maxEntries))
	CMInit(memoryLimitBytes)
}

// CMRegister makes a call ID cancellable. Call it before scheduling CMCallBytes.
//
//export CMRegister
func CMRegister(callID C.longlong) {
	registerCall(int64(callID))
}

// CMCallBytes runs one engine method and returns its JSON as bytes, with their count in length.
// They're copied once, into memory the caller owns, and never through a string: a big listing
// would otherwise sit in memory several times over at once. Free the result with CMFree.
//
//export CMCallBytes
func CMCallBytes(callID C.longlong, method *C.char, arguments *C.char, length *C.longlong) unsafe.Pointer {
	result := runCall(int64(callID), C.GoString(method), []byte(C.GoString(arguments)))
	*length = C.longlong(len(result))
	answer := C.CBytes(result)
	if lean {
		// iOS counts memory Go has finished with until it's handed back, and a listing or a
		// download leaves plenty behind.
		trimMemory()
	}
	return answer
}

// CMCancel cancels a running call.
//
//export CMCancel
func CMCancel(callID C.longlong) {
	cancelCall(int64(callID))
}

// CMProgress returns the bytes a call has moved, or -1 if it isn't running.
//
//export CMProgress
func CMProgress(callID C.longlong) C.longlong {
	return C.longlong(callProgress(int64(callID)))
}

// CMFree releases what the engine returned.
//
//export CMFree
func CMFree(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func main() {}
