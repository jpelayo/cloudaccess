// Apache 2 license - developer@infinitecontext.com

// Command credits writes Credits.json: every module compiled into the engine, per platform, with
// its licence text, plus Go itself and, for the iPhone, VLCKit. Both apps show it in About.
//
// It's generated so it can't drift from what ships. A licence it can't name stops the run, so a
// person reads it before an app carries it: nothing is ever guessed.
//
// Usage, from Engine/: go run ./cmd/credits -out <Credits.json> -vlckit <Binaries folder> [-check]
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type credit struct {
	Name      string   `json:"name"`
	Version   string   `json:"version"`
	Licence   string   `json:"licence"`
	Text      string   `json:"text"`
	Platforms []string `json:"platforms"`
}

// The platforms the engine is built for, as Engine/build.sh builds them. The simulator compiles
// the same code as the device.
var targets = []struct{ platform, goos, goarch string }{
	{"macOS", "darwin", "arm64"},
	{"macOS", "darwin", "amd64"},
	{"iOS", "ios", "arm64"},
}

func main() {
	out := flag.String("out", "", "where Credits.json goes")
	vlckit := flag.String("vlckit", "", "the folder fetch-vlckit.sh fills")
	check := flag.Bool("check", false, "only compare with the file already there")
	flag.Parse()
	if *out == "" || *vlckit == "" {
		fail(errors.New("usage: credits -out <Credits.json> -vlckit <Binaries folder> [-check]"))
	}

	credits, err := gather(*vlckit)
	if err != nil {
		fail(err)
	}
	rendered, err := render(credits)
	if err != nil {
		fail(err)
	}
	if *check {
		existing, _ := os.ReadFile(*out)
		if !bytes.Equal(existing, rendered) {
			fail(errors.New("Credits.json is out of date: run Tools/make-credits.sh"))
		}
		return
	}
	if err := os.WriteFile(*out, rendered, 0o644); err != nil {
		fail(err)
	}
	fmt.Printf("%d credits written to %s\n", len(credits), *out)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func gather(vlckit string) (map[string]*credit, error) {
	credits := map[string]*credit{}
	add := func(c credit, platform string) {
		if existing, ok := credits[c.Name]; ok {
			if !contains(existing.Platforms, platform) {
				existing.Platforms = append(existing.Platforms, platform)
			}
			return
		}
		c.Platforms = []string{platform}
		credits[c.Name] = &c
	}

	for _, target := range targets {
		modules, err := listModules(target.goos, target.goarch)
		if err != nil {
			return nil, err
		}
		for _, m := range modules {
			names, text, err := readLicence(m.Dir)
			if err != nil {
				return nil, fmt.Errorf("%s %s: %w", m.Path, m.Version, err)
			}
			add(credit{Name: m.Path, Version: m.Version, Licence: names, Text: text}, target.platform)
		}
	}

	goCredit, err := goItself()
	if err != nil {
		return nil, err
	}
	for _, platform := range []string{"macOS", "iOS"} {
		add(goCredit, platform)
	}

	vlc, err := vlcKit(vlckit)
	if err != nil {
		return nil, err
	}
	add(vlc, "iOS")
	return credits, nil
}

func contains(list []string, item string) bool {
	for _, each := range list {
		if each == item {
			return true
		}
	}
	return false
}

type module struct {
	Path, Version, Dir string
	Main               bool
	Replace            *module
}

// listModules names the modules `go build` would compile for one platform: the packages the
// engine imports, not everything go.mod lists.
func listModules(goos, goarch string) ([]module, error) {
	cmd := exec.Command("go", "list", "-deps", "-json", ".")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=1", "GOOS="+goos, "GOARCH="+goarch)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("go list for %s/%s: %w: %s", goos, goarch, err, stderr.String())
	}
	seen := map[string]module{}
	decoder := json.NewDecoder(bytes.NewReader(output))
	for decoder.More() {
		var pkg struct{ Module *module }
		if err := decoder.Decode(&pkg); err != nil {
			return nil, err
		}
		if pkg.Module == nil || pkg.Module.Main {
			continue
		}
		m := *pkg.Module
		if m.Replace != nil {
			m.Version, m.Dir = m.Replace.Version, m.Replace.Dir
		}
		if m.Dir == "" {
			return nil, fmt.Errorf("%s %s isn't in the module cache: run go mod download", m.Path, m.Version)
		}
		seen[m.Path] = m
	}
	modules := make([]module, 0, len(seen))
	for _, m := range seen {
		modules = append(modules, m)
	}
	return modules, nil
}

var (
	licenceFile = regexp.MustCompile(`(?i)^(licen[cs]e|copying|unlicense)([-._].*)?$`)
	noticeFile  = regexp.MustCompile(`(?i)^notice([-._].*)?$`)
)

// readLicence takes a module's licence files, then its NOTICE, which Apache 2 asks to be passed
// on with the licence.
func readLicence(dir string) (names, text string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", "", err
	}
	var licences, notices []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		switch name := entry.Name(); {
		case licenceFile.MatchString(name):
			licences = append(licences, name)
		case noticeFile.MatchString(name):
			notices = append(notices, name)
		}
	}
	if len(licences) == 0 {
		return "", "", errors.New("no licence file")
	}
	sort.Strings(licences)
	sort.Strings(notices)

	found := map[string]bool{}
	var parts []string
	for _, name := range licences {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", "", err
		}
		kinds, err := classify(string(data))
		if err != nil {
			return "", "", fmt.Errorf("%s: %w", name, err)
		}
		for _, kind := range kinds {
			found[kind] = true
		}
		parts = append(parts, strings.TrimSpace(string(data)))
	}
	for _, name := range notices {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", "", err
		}
		parts = append(parts, strings.TrimSpace(string(data)))
	}
	return joinKinds(found), strings.Join(parts, "\n\n"+strings.Repeat("-", 40)+"\n\n"), nil
}

func joinKinds(found map[string]bool) string {
	kinds := make([]string, 0, len(found))
	for kind := range found {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	return strings.Join(kinds, ", ")
}

// classify names the licences a text holds, by phrases each licence's own wording carries.
func classify(text string) ([]string, error) {
	flat := strings.Join(strings.Fields(text), " ")
	has := func(phrase string) bool { return strings.Contains(flat, phrase) }
	found := map[string]bool{}

	if has("Apache License") && has("Version 2.0") {
		found["Apache-2.0"] = true
	}
	if has("Permission is hereby granted, free of charge") {
		found["MIT"] = true
	}
	if has("Redistribution and use in source and binary forms") {
		if has("Neither the name") || has("names of its contributors may be used") {
			found["BSD-3-Clause"] = true
		} else {
			found["BSD-2-Clause"] = true
		}
	}
	if has("Permission to use, copy, modify, and/or distribute this software for any purpose") ||
		has("Permission to use, copy, modify, and distribute this software for any purpose") {
		found["ISC"] = true
	}
	if has("Mozilla Public License") && (has("Version 2.0") || has("version 2.0")) {
		found["MPL-2.0"] = true
	}
	if has("GNU LESSER GENERAL PUBLIC LICENSE") && has("Version 2.1") {
		found["LGPL-2.1"] = true
	}
	if has("CC0 1.0 Universal") {
		found["CC0-1.0"] = true
	}
	if has("This is free and unencumbered software released into the public domain") {
		found["Unlicense"] = true
	}
	if len(found) == 0 {
		return nil, errors.New("licence not recognised: read it, and add it to classify only if the apps may carry it")
	}
	kinds := make([]string, 0, len(found))
	for kind := range found {
		kinds = append(kinds, kind)
	}
	sort.Strings(kinds)
	return kinds, nil
}

// goItself is the standard library and runtime, compiled into every Go program.
func goItself() (credit, error) {
	run := func(args ...string) (string, error) {
		output, err := exec.Command("go", args...).Output()
		return strings.TrimSpace(string(output)), err
	}
	root, err := run("env", "GOROOT")
	if err != nil {
		return credit{}, err
	}
	version, err := run("env", "GOVERSION")
	if err != nil {
		return credit{}, err
	}
	// Go's own download keeps it in GOROOT; Homebrew moves it one folder up.
	var data []byte
	for _, place := range []string{root, filepath.Dir(root)} {
		if data, err = os.ReadFile(filepath.Join(place, "LICENSE")); err == nil {
			break
		}
	}
	if err != nil {
		return credit{}, fmt.Errorf("Go's licence isn't beside GOROOT: %w", err)
	}
	kinds, err := classify(string(data))
	if err != nil {
		return credit{}, fmt.Errorf("Go: %w", err)
	}
	text := strings.TrimSpace(string(data))
	// Go's patent grant comes with its licence.
	if patents, err := os.ReadFile(filepath.Join(root, "PATENTS")); err == nil {
		text += "\n\n" + strings.Repeat("-", 40) + "\n\n" + strings.TrimSpace(string(patents))
	}
	return credit{
		Name: "Go", Version: strings.TrimPrefix(version, "go"),
		Licence: strings.Join(kinds, ", "), Text: text,
	}, nil
}

// vlcKit is the iPhone's player, from the files fetch-vlckit.sh leaves beside it.
func vlcKit(folder string) (credit, error) {
	data, err := os.ReadFile(filepath.Join(folder, "MobileVLCKit-COPYING.txt"))
	if err != nil {
		return credit{}, fmt.Errorf("VLCKit's licence is missing: run Packages/Player/fetch-vlckit.sh: %w", err)
	}
	version, err := os.ReadFile(filepath.Join(folder, "MobileVLCKit.version"))
	if err != nil {
		return credit{}, fmt.Errorf("VLCKit's version is missing: run Packages/Player/fetch-vlckit.sh: %w", err)
	}
	kinds, err := classify(string(data))
	if err != nil {
		return credit{}, fmt.Errorf("VLCKit: %w", err)
	}
	return credit{
		Name: "VLCKit", Version: strings.TrimSpace(string(version)),
		Licence: strings.Join(kinds, ", "), Text: strings.TrimSpace(string(data)),
	}, nil
}

// render sorts by name, ignoring case, so the file only changes when what ships does.
func render(credits map[string]*credit) ([]byte, error) {
	list := make([]credit, 0, len(credits))
	for _, c := range credits {
		each := *c
		each.Platforms = append([]string(nil), c.Platforms...)
		sort.Strings(each.Platforms)
		list = append(list, each)
	}
	sort.Slice(list, func(i, j int) bool {
		return strings.ToLower(list[i].Name) < strings.ToLower(list[j].Name)
	})
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}
