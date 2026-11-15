#!/bin/bash
# Apache 2 license - developer@infinitecontext.com
# Downloads VideoLAN's own MobileVLCKit build, checks it against the checksum VideoLAN publishes
# in its CocoaPods spec, and unpacks it to Binaries/MobileVLCKit.xcframework. CloudWanderer's
# player links it for the formats Apple's player can't open. Run it once before building the
# iPhone app; it does nothing if the right version is already there.
# Usage: Packages/Player/fetch-vlckit.sh
set -euo pipefail

VERSION="3.7.5"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.5-a213fd11-6de05adc.tar.xz"
SHA256="a76f7a6cfcde4209b56f943e6e18400659d8a7a93ff482f8b1d059468d11e6be"

HERE="$(cd "$(dirname "$0")" && pwd)"
BINARIES="$HERE/Binaries"
STAMP="$BINARIES/MobileVLCKit.version"

if [ -d "$BINARIES/MobileVLCKit.xcframework" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ]; then
  echo "MobileVLCKit $VERSION is already in place."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading MobileVLCKit $VERSION (about 260 MB)…"
curl --fail --location --silent --show-error --output "$WORK/vlckit.tar.xz" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/vlckit.tar.xz" | cut -d ' ' -f 1)"
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "The download doesn't match VideoLAN's checksum, so it wasn't used." >&2
  echo "Expected $SHA256" >&2
  echo "Got      $ACTUAL" >&2
  exit 1
fi

tar -xJf "$WORK/vlckit.tar.xz" -C "$WORK"
FOUND="$(find "$WORK" -maxdepth 3 -name MobileVLCKit.xcframework -type d | head -n 1)"
if [ -z "$FOUND" ]; then
  echo "MobileVLCKit.xcframework wasn't in the download." >&2
  exit 1
fi

mkdir -p "$BINARIES"
rm -rf "$BINARIES/MobileVLCKit.xcframework"
mv "$FOUND" "$BINARIES/MobileVLCKit.xcframework"
# VideoLAN's licence and notice, for the app's About screen and the release's licence list.
for notice in COPYING.txt NEWS.txt; do
  FILE="$(find "$WORK" -maxdepth 3 -name "$notice" | head -n 1)"
  [ -n "$FILE" ] && cp "$FILE" "$BINARIES/MobileVLCKit-$notice"
done
echo "$VERSION" > "$STAMP"
echo "MobileVLCKit $VERSION is in $BINARIES."
