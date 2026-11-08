// Apache 2 license - developer@infinitecontext.com

// Command testdav serves a folder over WebDAV for local tests. Unlike rclone serve, its MKCOL
// fails on an existing folder, as Apache's does, and claims depend on that.
//
// Usage: testdav <folder> <address>
package main

import (
	"log"
	"net/http"
	"os"

	"golang.org/x/net/webdav"
)

func main() {
	if len(os.Args) != 3 {
		log.Fatal("usage: testdav <folder> <address>")
	}
	handler := &webdav.Handler{
		FileSystem: webdav.Dir(os.Args[1]),
		LockSystem: webdav.NewMemLS(),
	}
	log.Fatal(http.ListenAndServe(os.Args[2], handler))
}
