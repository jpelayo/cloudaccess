// Apache 2 license - developer@infinitecontext.com

package main

import (
	"errors"
	"runtime"
)

// errFolderTooBig is a folder with more items than a lean engine lists. It's refused whole:
// a listing with items left out would tell the system those items were gone.
var errFolderTooBig = errors.New("this folder has too many items to list here")

// The lean settings are for a process that iOS stops at a small size, such as the iPhone's
// Files extension. They're set once, before any drive opens, and never change after.
var (
	lean bool
	// maxListing is the most entries a lean engine lists in one folder. 0 means no limit.
	maxListing int
	// sftpRequestsInFlight bounds what an SFTP read buffers. rclone's 64 requests of 32 KiB
	// each would be 2 MiB for one file.
	sftpRequestsInFlight = 4
	// sftpIdleTimeout closes an unused SFTP session soon, where rclone waits a minute holding its
	// buffers.
	sftpIdleTimeout = "5s"
)

// useLean trades speed for memory: one thread running Go at a time, one listing at a time, a
// cap on folder size, and memory given back after every call. Every extra thread for Go costs
// stacks and allocator caches, and with one transfer and one listing at a time a second buys
// nothing; Tailscale runs its iPhone extension the same way.
func useLean(entries int) {
	lean = true
	maxListing = entries
	runtime.GOMAXPROCS(1)
	listingSlots = make(chan struct{}, 1)
}

// checkListingSize refuses a folder too big for a lean engine, before any of it is converted.
func checkListingSize(count int) error {
	if maxListing > 0 && count > maxListing {
		return errFolderTooBig
	}
	return nil
}
