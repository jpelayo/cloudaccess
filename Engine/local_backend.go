// Apache 2 license - developer@infinitecontext.com

//go:build !ios

package main

// The local backend serves only the offline tests, which run on the Mac through the C interface.
// The iPhone never has a local drive, and every package linked in costs its Files extension
// memory that iOS counts, so it's left out there.
import _ "github.com/rclone/rclone/backend/local"
