// Apache 2 license - developer@infinitecontext.com

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const mitText = `MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction.`

const bsd3Text = `Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.`

const bsd2Text = `Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice.
2. Redistributions in binary form must reproduce the above copyright notice.`

const apacheText = `                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/`

const iscText = `Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.`

const mplText = `Mozilla Public License Version 2.0
==================================`

const lgplText = `                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999`

const cc0Text = `Creative Commons Legal Code

CC0 1.0 Universal`

func TestEachLicenceIsNamedByItsText(t *testing.T) {
	cases := map[string]string{
		mitText:    "MIT",
		bsd3Text:   "BSD-3-Clause",
		bsd2Text:   "BSD-2-Clause",
		apacheText: "Apache-2.0",
		iscText:    "ISC",
		mplText:    "MPL-2.0",
		lgplText:   "LGPL-2.1",
		cc0Text:    "CC0-1.0",
	}
	for text, want := range cases {
		got, err := classify(text)
		if err != nil || strings.Join(got, ", ") != want {
			t.Errorf("classify(%q…) = %v, %v; want %s", text[:20], got, err, want)
		}
	}
}

func TestOneFileWithTwoLicencesNamesBoth(t *testing.T) {
	got, err := classify(mitText + "\n\n" + apacheText)
	if err != nil || strings.Join(got, ", ") != "Apache-2.0, MIT" {
		t.Fatalf("got %v, %v", got, err)
	}
}

// A licence nobody recognised must stop the run, so a person reads it before the app ships.
func TestAnUnknownLicenceFails(t *testing.T) {
	for _, text := range []string{
		"All rights reserved.",
		"                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007",
	} {
		if got, err := classify(text); err == nil {
			t.Errorf("classify(%q) = %v, want an error", text, got)
		}
	}
}

func write(t *testing.T, dir, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestAModuleWithANoticeKeepsIt(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "LICENSE", apacheText)
	write(t, dir, "NOTICE", "This product includes software developed by someone.")
	write(t, dir, "README.md", "Not a licence.")

	names, text, err := readLicence(dir)
	if err != nil {
		t.Fatal(err)
	}
	if names != "Apache-2.0" {
		t.Errorf("names = %q", names)
	}
	if !strings.Contains(text, "Version 2.0") || !strings.Contains(text, "developed by someone") {
		t.Errorf("text lost a file: %q", text)
	}
	if strings.Contains(text, "Not a licence") {
		t.Errorf("text took a file that isn't a licence")
	}
	if strings.Index(text, "Version 2.0") > strings.Index(text, "developed by someone") {
		t.Errorf("the notice should follow the licence")
	}
}

func TestAModuleWithTwoLicenceFilesNamesBoth(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "LICENSE-APACHE", apacheText)
	write(t, dir, "LICENSE-MIT", mitText)

	names, _, err := readLicence(dir)
	if err != nil || names != "Apache-2.0, MIT" {
		t.Fatalf("names = %q, %v", names, err)
	}
}

func TestAModuleWithNoLicenceFails(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "README.md", "No licence here.")
	if _, _, err := readLicence(dir); err == nil {
		t.Fatal("want an error")
	}
}

func TestTheListIsSortedAndStable(t *testing.T) {
	credits := map[string]*credit{
		"golang.org/x/net":         {Name: "golang.org/x/net", Platforms: []string{"macOS", "iOS"}},
		"Go":                       {Name: "Go", Platforms: []string{"iOS", "macOS"}},
		"github.com/pkg/sftp":      {Name: "github.com/pkg/sftp", Platforms: []string{"iOS"}},
		"github.com/Azure/ntlmssp": {Name: "github.com/Azure/ntlmssp", Platforms: []string{"macOS"}},
	}
	first, err := render(credits)
	if err != nil {
		t.Fatal(err)
	}
	second, _ := render(credits)
	if string(first) != string(second) {
		t.Fatal("two renders differ")
	}
	order := []string{"github.com/Azure/ntlmssp", "github.com/pkg/sftp", "Go", "golang.org/x/net"}
	at := -1
	for _, name := range order {
		next := strings.Index(string(first), `"`+name+`"`)
		if next < at {
			t.Fatalf("%s is out of order", name)
		}
		at = next
	}
	if !strings.Contains(string(first), `"platforms": [
      "iOS",
      "macOS"
    ]`) {
		t.Errorf("platforms aren't sorted: %s", first)
	}
}
