#!/usr/bin/env bash
# 构建 release 二进制并组装成 dist/GlassVPN.app + zip。需要在装有 Xcode 26+ 的 macOS 上运行 (本机或 GitHub Actions)。
#   VERSION           CFBundleShortVersionString, 默认 0.1.0
#   BUILD             CFBundleVersion, 默认 1
#   ARCH              arm64 / x86_64, 默认 arm64
#   BUNDLE_CORE       1 = 内置 sing-box 内核 (默认), 0 = 不内置, 由用户在应用内下载
#   SING_BOX_VERSION  内置的内核版本, 如 1.12.8; 默认取 SagerNet/sing-box 最新正式版
#   GITHUB_TOKEN      可选, 查询最新版本时使用, 避免 GitHub API 匿名访问频率限制
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
ARCH="${ARCH:-arm64}"
BUNDLE_CORE="${BUNDLE_CORE:-1}"
NAME="GlassVPN"
HELPER="gvpnhelper"
CORE="sing-box"

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

CORE_VERSION=""
if [[ "$BUNDLE_CORE" == "1" ]]; then
    case "$ARCH" in
        arm64) CORE_ARCH="arm64" ;;
        x86_64) CORE_ARCH="amd64" ;;
        *) echo "unsupported ARCH: $ARCH" >&2; exit 1 ;;
    esac
    CORE_VERSION="${SING_BOX_VERSION:-}"
    if [[ -z "$CORE_VERSION" ]]; then
        AUTH=()
        [[ -n "${GITHUB_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
        # releases/latest 不含预发布版本
        CORE_VERSION="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} \
            https://api.github.com/repos/SagerNet/sing-box/releases/latest \
            | plutil -extract tag_name raw -o - -)"
    fi
    CORE_VERSION="${CORE_VERSION#v}"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    TARBALL="sing-box-$CORE_VERSION-darwin-$CORE_ARCH.tar.gz"
    echo "== bundling $TARBALL =="
    curl -fsSL -o "$WORK/core.tar.gz" \
        "https://github.com/SagerNet/sing-box/releases/download/v$CORE_VERSION/$TARBALL"
    tar -xzf "$WORK/core.tar.gz" -C "$WORK"
    OUT="$APP/Contents/MacOS/$CORE"
    cp "$WORK/sing-box-$CORE_VERSION-darwin-$CORE_ARCH/$CORE" "$OUT"
    chmod +x "$OUT"
    "$OUT" version
fi

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__CORE_VERSION__/$CORE_VERSION/" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名: Apple Silicon 要求可执行文件至少有签名; 先签内层工具再签整个 App
for BIN in "$HELPER" "$CORE"; do
    if [[ -f "$APP/Contents/MacOS/$BIN" ]]; then
        codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$BIN"
    fi
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$DIST/$NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== size =="
du -sh "$APP"
ls -l "$APP/Contents/MacOS/" "$ZIP"
vtool -show-build "$APP/Contents/MacOS/$NAME"
