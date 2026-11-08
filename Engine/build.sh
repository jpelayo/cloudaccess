#!/bin/bash
# Apache 2 license - developer@infinitecontext.com
# Builds CEngine.xcframework for macOS, iOS devices and the iOS simulator,
# into Packages/CloudCore/Binaries.
# Usage: Engine/build.sh [all|ios]
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$ENGINE_DIR/build"
MIN_MACOS=26.0
MIN_IOS=26.0
MODE="${1:-all}"

# build <slice> <goos> <goarch> <sdk> <clang target>
build() {
  local slice=$1 goos=$2 goarch=$3 sdk=$4 target=$5
  local clang sysroot
  clang="$(xcrun --sdk "$sdk" --find clang)"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  mkdir -p "$OUT/$slice"
  echo "Building $slice"
  (
    cd "$ENGINE_DIR"
    CGO_ENABLED=1 GOOS="$goos" GOARCH="$goarch" \
      CC="$clang -isysroot $sysroot -target $target" \
      CGO_CFLAGS="-isysroot $sysroot -target $target" \
      CGO_LDFLAGS="-isysroot $sysroot -target $target" \
      go build -trimpath -buildmode=c-archive -ldflags='-s -w' \
      -o "$OUT/$slice/libengine.a" .
  )
}

build ios-arm64 ios arm64 iphoneos "arm64-apple-ios$MIN_IOS"
build ios-simulator-arm64 ios arm64 iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"
[ "$MODE" = "ios" ] && exit 0

build macos-arm64 darwin arm64 macosx "arm64-apple-macos$MIN_MACOS"
build macos-x86_64 darwin amd64 macosx "x86_64-apple-macos$MIN_MACOS"

mkdir -p "$OUT/macos"
lipo -create "$OUT/macos-arm64/libengine.a" "$OUT/macos-x86_64/libengine.a" \
  -output "$OUT/macos/libengine.a"

HEADERS="$OUT/headers"
mkdir -p "$HEADERS"
cp "$OUT/macos-arm64/libengine.h" "$HEADERS/CEngine.h"
cat > "$HEADERS/module.modulemap" <<'EOF'
module CEngine {
  header "CEngine.h"
  export *
}
EOF

FRAMEWORK="$ENGINE_DIR/../Packages/CloudCore/Binaries/CEngine.xcframework"
mkdir -p "$(dirname "$FRAMEWORK")"
# Built beside the old one and swapped in by renaming, so an open Xcode never finds it missing
# and loses track of the package.
FRESH="$OUT/CEngine.xcframework"
rm -rf "$FRESH" "$OUT/previous.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/macos/libengine.a" -headers "$HEADERS" \
  -library "$OUT/ios-arm64/libengine.a" -headers "$HEADERS" \
  -library "$OUT/ios-simulator-arm64/libengine.a" -headers "$HEADERS" \
  -output "$FRESH"
if [ -e "$FRAMEWORK" ]; then
  mv "$FRAMEWORK" "$OUT/previous.xcframework"
fi
mv "$FRESH" "$FRAMEWORK"
rm -rf "$OUT/previous.xcframework"

du -sh "$OUT"/*/libengine.a "$FRAMEWORK"
