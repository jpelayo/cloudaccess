// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The iPhone's Files extension is stopped by iOS at a small size, so its engine refuses a folder
// too big to hold. The refusal has to be whole: a listing with items left out would tell the
// system those items were gone.
func TestALeanEngineRefusesAFolderTooBigWhole(t *testing.T) {
	ctx := context.Background()
	d, _, folder := meddledDrive(t)
	for i := range 5 {
		name := filepath.Join(folder, fmt.Sprintf("file-%d.txt", i))
		if err := os.WriteFile(name, []byte("contents"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	saved := maxListing
	t.Cleanup(func() { maxListing = saved })

	maxListing = 100
	items, err := d.list(ctx, "")
	if err != nil || len(items) != 5 {
		t.Fatalf("a folder under the limit wasn't listed whole: %d items, %v", len(items), err)
	}

	maxListing = 3
	items, err = d.list(ctx, "")
	if err == nil || items != nil {
		t.Fatalf("a folder over the limit was listed in part: %d items, %v", len(items), err)
	}
	if kind := classify(err).Kind; kind != "tooManyItems" {
		t.Fatalf("a folder over the limit was reported as %q", kind)
	}
}

// tallyReader reports how much of a body was read.
type tallyReader struct {
	r    io.Reader
	read int
}

func (c *tallyReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.read += n
	return n, err
}

func listingOf(children int) string {
	var body strings.Builder
	body.WriteString(`<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">`)
	body.WriteString(`<D:response><D:href>/folder/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`)
	for i := range children {
		fmt.Fprintf(&body, `<D:response><D:href>/folder/file-%d.txt</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>8</D:getcontentlength><D:getetag>"e%d"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`, i, i)
	}
	body.WriteString(`</D:multistatus>`)
	return body.String()
}

// The limit is checked while the listing is read, so a big folder is refused before the rest of
// it is in memory, which is what would have iOS stop the extension.
func TestALeanEngineStopsReadingABigFolderEarly(t *testing.T) {
	saved := maxListing
	t.Cleanup(func() { maxListing = saved })
	maxListing = 3
	document := listingOf(2_000)
	body := &tallyReader{r: strings.NewReader(document)}
	_, err := decodeMultistatus(body)
	if kind := classify(err).Kind; kind != "tooManyItems" {
		t.Fatalf("a folder over the limit was reported as %q: %v", kind, err)
	}
	if body.read > len(document)/10 {
		t.Fatalf("read %d of %d bytes before refusing", body.read, len(document))
	}
}

// Reading one entry at a time accepts the same listing decoding it whole did.
func TestAListingReadInPiecesMatchesTheWhole(t *testing.T) {
	document := listingOf(50)
	var whole multistatus
	if err := xml.NewDecoder(strings.NewReader(document)).Decode(&whole); err != nil {
		t.Fatal(err)
	}
	pieces, err := decodeMultistatus(strings.NewReader(document))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(whole, pieces) {
		t.Fatalf("the listings differ: %d against %d entries", len(whole.Responses), len(pieces.Responses))
	}
	if _, err := decodeMultistatus(strings.NewReader("")); err == nil {
		t.Fatal("an empty body was read as a listing")
	}
	if _, err := decodeMultistatus(strings.NewReader(document[:len(document)/2])); err == nil {
		t.Fatal("half a listing was read as a whole one")
	}
}

// Without the lean setting there's no limit at all, so the Mac lists any folder.
func TestTheMacListsAnyFolder(t *testing.T) {
	if maxListing != 0 || lean {
		t.Fatalf("the engine starts lean: limit %d", maxListing)
	}
	if err := checkListingSize(1_000_000); err != nil {
		t.Fatalf("a large folder was refused without the lean setting: %v", err)
	}
}
