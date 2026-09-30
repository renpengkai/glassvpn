#!/usr/bin/env bash
# 构建 release 二进制并组装成 dist/GlassVPN.app + zip。需要在装有 Xcode 26+ 的 macOS 上运行 (本机或 GitHub Actions)。
#   VERSION  CFBundleShortVersionString, 默认 0.1.0
#   BUILD    CFBundleVersion, 默认 1
#   ARCH     arm64 / x86_64, 默认 arm64
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
ARCH="${ARCH:-arm64}"
NAME="GlassVPN"
HELPER="gvpnhelper"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

DIST="$ROOT/dist"
APP="$DIST/$NAME.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS"

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
for BIN in "$NAME" "$HELPER"; do
    OUT="$APP/Contents/MacOS/$BIN"
    cp "$BIN_DIR/$BIN" "$OUT"
    strip -S -x "$OUT"
    # SwiftPM 把 LC_BUILD_VERSION 的 sdk 写成部署目标 (13.0), 系统据此按旧 SDK 兼容模式运行,
    # 不会启用液态玻璃; 改写为实际编译所用的 SDK 版本
    vtool -set-build-version macos 13.0 "$SDK_VERSION" -replace -output "$OUT.tmp" "$OUT"
    mv "$OUT.tmp" "$OUT"
    chmod +x "$OUT"
done

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名: Apple Silicon 要求可执行文件至少有签名; 先签内层工具再签整个 App
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$HELPER"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$DIST/$NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== size =="
du -sh "$APP"
ls -l "$APP/Contents/MacOS/" "$ZIP"
vtool -show-build "$APP/Contents/MacOS/$NAME"
