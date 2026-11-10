// Apache 2 license - developer@infinitecontext.com

package main

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/rclone/rclone/backend/webdav/api"
	"github.com/rclone/rclone/fs/fshttp"
)

// errBadReply means something answered that isn't a WebDAV server speaking sense, such as a
// network's sign-in page. It says nothing about the item, so it can never mean the item is gone.
var errBadReply = errors.New("the server's reply didn't make sense")

// errUnreadableEntry means the server named an item but gave no usable details. A listing leaves
// such an item out, and a direct check reports this, which removes nothing.
var errUnreadableEntry = errors.New("the server gave no usable details for this item")

var (
	// firstByteLimit is how long a server gets to start answering.
	firstByteLimit = 30 * time.Second
	// listingLimit is how long Finder is left waiting for a folder.
	listingLimit = 30 * time.Second
)

// davClient makes the few WebDAV requests rclone's backend doesn't offer: listings that
// include ETags, and moves and folder creation with exact control over their conditions.
// File transfers still go through rclone.
type davClient struct {
	endpoint string
	user     string
	password string
	client   *http.Client
}

func newDavClient(ctx context.Context, endpoint, user, password string) *davClient {
	client := *fshttp.NewClient(ctx)
	// Go turns a redirected PROPFIND into a GET, so redirects are handled here instead.
	client.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &davClient{
		endpoint: strings.TrimRight(endpoint, "/"),
		user:     user,
		password: password,
		client:   &client,
	}
}

func (c *davClient) address(rawPath string, folder bool) string {
	var encoded strings.Builder
	encoded.WriteString(c.endpoint)
	for _, part := range strings.Split(rawPath, "/") {
		// A dot segment could climb out of the drive, however the path got here.
		if part != "" && part != "." && part != ".." {
			encoded.WriteByte('/')
			encoded.WriteString(url.PathEscape(part))
		}
	}
	if folder {
		encoded.WriteByte('/')
	}
	return encoded.String()
}

func (c *davClient) do(
	ctx context.Context, method, address string, headers map[string]string, body io.Reader,
) (*http.Response, error) {
	waiting, cancel := context.WithCancel(ctx)
	request, err := http.NewRequestWithContext(waiting, method, address, body)
	if err != nil {
		cancel()
		return nil, err
	}
	if c.user != "" {
		request.SetBasicAuth(c.user, c.password)
	}
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	var tooSlow atomic.Bool
	timer := time.AfterFunc(firstByteLimit, func() {
		tooSlow.Store(true)
		cancel()
	})
	response, err := c.client.Do(request)
	timer.Stop()
	if err != nil {
		cancel()
		if tooSlow.Load() {
			return nil, fmt.Errorf("%w: %v", errTooSlow, err)
		}
		return nil, err
	}
	response.Body = cancelOnClose{response.Body, cancel}
	return response, nil
}

// offersOnlyDigest reports whether the server turned down Basic sign-in and offered only Digest.
func (c *davClient) offersOnlyDigest(ctx context.Context) bool {
	response, err := c.do(ctx, "OPTIONS", c.address("", true), nil, nil)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		return false
	}
	digest := false
	for _, challenge := range response.Header.Values("WWW-Authenticate") {
		scheme, _, _ := strings.Cut(strings.TrimSpace(challenge), " ")
		switch strings.ToLower(scheme) {
		case "basic":
			return false
		case "digest":
			digest = true
		}
	}
	return digest
}

// cancelOnClose ends a request's context with its body, which has to outlive the request itself.
type cancelOnClose struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c cancelOnClose) Close() error {
	defer c.cancel()
	return c.ReadCloser.Close()
}

func statusError(status int) error {
	return &api.Error{StatusCode: status, Status: http.StatusText(status)}
}

type multistatus struct {
	Responses []davResponse `xml:"response"`
}

type davResponse struct {
	Href      string `xml:"href"`
	Propstats []struct {
		Status string `xml:"status"`
		Prop   struct {
			Type struct {
				Collection *struct{} `xml:"collection"`
			} `xml:"resourcetype"`
			Length   string `xml:"getcontentlength"`
			Modified string `xml:"getlastmodified"`
			ETag     string `xml:"getetag"`
			// Details is this app's own property, and only in its namespace.
			Details string `xml:"https://infinitecontext.com/ns/cloudaccess/ file"`
		} `xml:"prop"`
	} `xml:"propstat"`
}

// decodeMultistatus reads a listing one entry at a time. It accepts exactly what decoding the
// whole document into a multistatus would, and a lean engine stops at its limit before reading
// the rest, which in a big folder would be more memory than iOS gives the Files extension.
func decodeMultistatus(body io.Reader) (multistatus, error) {
	var parsed multistatus
	decoder := xml.NewDecoder(body)
	depth := 0
	sawRoot := false
	for {
		token, err := decoder.Token()
		if err != nil {
			if errors.Is(err, io.EOF) && sawRoot && depth == 0 {
				return parsed, nil
			}
			return multistatus{}, fmt.Errorf("unreadable listing: %w", err)
		}
		switch element := token.(type) {
		case xml.StartElement:
			if depth == 0 {
				sawRoot = true
				depth = 1
				continue
			}
			if depth == 1 && element.Name.Local == "response" {
				var entry davResponse
				if err := decoder.DecodeElement(&entry, &element); err != nil {
					return multistatus{}, fmt.Errorf("unreadable listing: %w", err)
				}
				parsed.Responses = append(parsed.Responses, entry)
				// The folder answers for itself too, so its children are one fewer.
				if err := checkListingSize(len(parsed.Responses) - 1); err != nil {
					return multistatus{}, err
				}
				continue
			}
			if err := decoder.Skip(); err != nil {
				return multistatus{}, fmt.Errorf("unreadable listing: %w", err)
			}
		case xml.EndElement:
			depth--
			if depth == 0 {
				// Whatever follows the document is ignored, as decoding it whole would.
				return parsed, nil
			}
		}
	}
}

// listingByteLimit bounds what one listing may read. A lean engine stops sooner, because iOS
// stops the Files extension long before 64 MiB.
func listingByteLimit() int64 {
	if lean {
		return maxLeanListingBytes
	}
	return maxListingBytes
}

const propfindBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:"><D:prop>
<D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:getetag/>
</D:prop></D:propfind>`

// propfindDetailsBody also asks for file details. Apache opens its property database for each item
// that asks, so only what can have details does.
const propfindDetailsBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:" xmlns:cm="` + detailsNamespace + `"><D:prop>
<D:resourcetype/><D:getcontentlength/><D:getlastmodified/><D:getetag/><cm:file/>
</D:prop></D:propfind>`

// wantsDetails says whether an item can have file details. The control folder holds only this
// app's own claims, staging files and vault, which never do.
func wantsDetails(rawPath string) bool {
	return rawPath != controlFolder && !strings.HasPrefix(rawPath, controlFolder+"/")
}

// Server responses are limited, so a bad server can't exhaust memory. A listing of 50,000
// items is about 30 MB.
const (
	maxListingBytes = 64 << 20
	// About three times what a folder at the lean limit takes, at a few hundred bytes an entry.
	maxLeanListingBytes = 16 << 20
	maxNameBytes        = 1024
	maxETagBytes        = 1024
)

// normalizeETag removes the weak marker: Apache serves a tag as weak for a second after
// a change, then serves the same value as strong.
func normalizeETag(tag string) string {
	return strings.TrimPrefix(strings.TrimSpace(tag), "W/")
}

// propfind lists a resource. With depth 1 the resource itself is left out.
func (c *davClient) propfind(ctx context.Context, rawPath, depth string, folder, details bool) ([]rawEntry, error) {
	address := c.address(rawPath, folder)
	headers := map[string]string{"Depth": depth, "Content-Type": "application/xml; charset=utf-8"}
	body := propfindBody
	if details {
		body = propfindDetailsBody
	}

	response, err := c.do(ctx, "PROPFIND", address, headers, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	// A folder asked for without its trailing slash redirects to the slash form.
	if response.StatusCode == http.StatusMovedPermanently || response.StatusCode == http.StatusFound {
		if folder {
			return nil, statusError(response.StatusCode)
		}
		return c.propfind(ctx, rawPath, depth, true, details)
	}
	// Go's WebDAV server answers 200 with nothing if the item vanished during the request. A 200
	// with content is something else answering, and that's no evidence about the item.
	if response.StatusCode == http.StatusOK {
		var first [1]byte
		// Only a body that really ended empty says that. One that broke says nothing at all, and
		// a false not-found would let a save replace the file without comparing versions.
		if count, err := io.ReadFull(response.Body, first[:]); count == 0 && errors.Is(err, io.EOF) {
			return nil, statusError(http.StatusNotFound)
		}
		return nil, errBadReply
	}
	if response.StatusCode != http.StatusMultiStatus {
		return nil, statusError(response.StatusCode)
	}

	parsed, err := decodeMultistatus(io.LimitReader(response.Body, listingByteLimit()))
	if err != nil {
		return nil, err
	}

	requested := strings.Trim(mustPath(address), "/")
	self, known := listingBase(requested, parsed)
	if !known && depth == "1" {
		return nil, errBadReply
	}
	entries := make([]rawEntry, 0, len(parsed.Responses))
	seen := make(map[string]bool, len(parsed.Responses))
	for _, item := range parsed.Responses {
		target := strings.Trim(mustPath(item.Href), "/")
		// A listing may only name what's directly inside the folder that was asked about.
		parent := path.Dir(target)
		if parent == "." {
			parent = ""
		}
		if depth == "1" && (target == self || parent != self) {
			continue
		}
		// A direct check must describe the item asked about, not whatever the server sent.
		if depth == "0" && rawPath != "" && !sameResource(requested, target) {
			continue
		}
		entry := rawEntry{Name: path.Base(target)}
		if len(entry.Name) > maxNameBytes || seen[entry.Name] {
			continue
		}
		seen[entry.Name] = true
		var isDescribed, hasLength, isDamaged bool
		for _, stat := range item.Propstats {
			if !strings.Contains(stat.Status, " 200 ") {
				continue
			}
			isDescribed = true
			entry.IsDirectory = entry.IsDirectory || stat.Prop.Type.Collection != nil
			if stat.Prop.Length != "" {
				size, err := strconv.ParseInt(stat.Prop.Length, 10, 64)
				isDamaged = isDamaged || err != nil || size < 0
				entry.Size = max(size, 0)
				hasLength = true
			}
			if stat.Prop.Modified != "" {
				entry.Modified, _ = http.ParseTime(stat.Prop.Modified)
			}
			if stat.Prop.ETag != "" && len(stat.Prop.ETag) <= maxETagBytes {
				entry.ETag = normalizeETag(stat.Prop.ETag)
			}
			if details := strings.TrimSpace(stat.Prop.Details); details != "" && len(details) <= maxDetailsReadBytes {
				entry.Details = details
			}
		}
		// Zero is a real size, so an item with no usable details can't be passed off as empty.
		if !isDescribed || isDamaged || (!entry.IsDirectory && !hasLength) {
			if depth == "0" {
				return nil, errUnreadableEntry
			}
			continue
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

// sameResource reports whether a reply is about the item asked for. A proxy can add or strip the
// start of a path, so one may end with the other, but the same name elsewhere is another item.
func sameResource(requested, target string) bool {
	return requested == target || strings.HasSuffix(requested, "/"+target) || strings.HasSuffix(target, "/"+requested)
}

// listingBase finds the folder a listing's paths are relative to. It's normally the requested
// path. A proxy can rewrite paths, and then the shortest entry is the folder itself, but only if
// everything else sits directly inside it, because a guess could misplace every item.
func listingBase(requested string, listing multistatus) (string, bool) {
	base := ""
	for _, item := range listing.Responses {
		target := strings.Trim(mustPath(item.Href), "/")
		if target == requested {
			return requested, true
		}
		if base == "" || len(target) < len(base) {
			base = target
		}
	}
	for _, item := range listing.Responses {
		target := strings.Trim(mustPath(item.Href), "/")
		if parent := path.Dir(target); target != base && parent != base {
			return "", false
		}
	}
	return base, true
}

// mustPath returns the decoded path of a URL or absolute path.
func mustPath(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	return parsed.Path
}

func (c *davClient) createExclusive(ctx context.Context, rawPath string) (bool, error) {
	status, err := c.mkcol(ctx, rawPath)
	if err != nil {
		return false, err
	}
	if status == http.StatusConflict {
		if err := c.ensureFolder(ctx, path.Dir(rawPath)); err != nil {
			return false, err
		}
		if status, err = c.mkcol(ctx, rawPath); err != nil {
			return false, err
		}
	}
	switch {
	case status == http.StatusCreated:
		return true, nil
	case status == http.StatusLocked, c.alreadyMade(ctx, status, rawPath):
		// Locked means a peer is working on this path right now, so it's busy, not broken.
		return false, nil
	}
	return false, statusError(status)
}

func (c *davClient) listRaw(ctx context.Context, rawPath string) ([]rawEntry, error) {
	return c.propfind(ctx, rawPath, "1", true, wantsDetails(rawPath))
}

func (c *davClient) statRaw(ctx context.Context, rawPath string) (rawEntry, error) {
	return c.stat(ctx, rawPath, wantsDetails(rawPath))
}

// statWithDetails is statRaw, asking for file details wherever the item is. The check that a
// server keeps them runs on a scratch file in the control folder.
func (c *davClient) statWithDetails(ctx context.Context, rawPath string) (rawEntry, error) {
	return c.stat(ctx, rawPath, true)
}

func (c *davClient) stat(ctx context.Context, rawPath string, details bool) (rawEntry, error) {
	entries, err := c.propfind(ctx, rawPath, "0", false, details)
	if err != nil {
		return rawEntry{}, err
	}
	if len(entries) == 0 {
		return rawEntry{}, errors.New("the server returned no details for this item")
	}
	return entries[0], nil
}

// detailsText escapes a value for an XML element. Quotes are fine in element text, and leaving
// them as they are keeps the value byte for byte what reads back.
var detailsText = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")

// setDetails sets this app's property on an item. The request carries no file content, so the
// file itself is never touched. It succeeds only if the server says it kept the property.
func (c *davClient) setDetails(ctx context.Context, rawPath string, folder bool, value string) error {
	body := `<?xml version="1.0" encoding="utf-8"?>` +
		`<D:propertyupdate xmlns:D="DAV:" xmlns:cm="` + detailsNamespace + `"><D:set><D:prop>` +
		`<cm:file>` + detailsText.Replace(value) + `</cm:file>` +
		`</D:prop></D:set></D:propertyupdate>`
	headers := map[string]string{"Content-Type": "application/xml; charset=utf-8"}
	response, err := c.do(ctx, "PROPPATCH", c.address(rawPath, folder), headers, strings.NewReader(body))
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusMultiStatus {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		return statusError(response.StatusCode)
	}
	var reply struct {
		Responses []struct {
			Propstats []struct {
				Status string `xml:"status"`
				Prop   struct {
					File *struct{} `xml:"https://infinitecontext.com/ns/cloudaccess/ file"`
				} `xml:"prop"`
			} `xml:"propstat"`
		} `xml:"response"`
	}
	if err := xml.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&reply); err != nil {
		return errBadReply
	}
	for _, item := range reply.Responses {
		for _, stat := range item.Propstats {
			if stat.Prop.File == nil {
				continue
			}
			if strings.Contains(stat.Status, " 200 ") {
				return nil
			}
			return fmt.Errorf("%w: %s", errDetailsRefused, strings.TrimSpace(stat.Status))
		}
	}
	return errDetailsRefused
}
