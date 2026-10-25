#!/bin/bash
# 构建 果冻桌宠：环境检查 → 编译 → 打包素材 → 本地签名 → 自检
#
#   ./build.sh                 编译并自检，产物在 build/JellyPet.app
#   ./build.sh --package       另外产出 dist/ 下的 zip、dmg 和 sha256 校验文件
#   ./build.sh --no-self-test  跳过自检（没有图形会话的环境里用）
#
# 环境变量：PET_VERSION（默认 1.0）、PET_BUILD（默认 1）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="JellyPet"
DISPLAY_NAME="果冻桌宠"
EXECUTABLE="JellyPet"
BUNDLE_ID="local.jelly.pet"
VERSION="${PET_VERSION:-1.0}"
BUILD_NUMBER="${PET_BUILD:-1}"
DEPLOY_TARGET="arm64-apple-macosx14.0"
BUNDLE="build/$APP_NAME.app"
DIST="dist"
PACKAGE=0
SELF_TEST=1

for arg in "$@"; do
    case "$arg" in
        --package) PACKAGE=1 ;;
        --no-self-test) SELF_TEST=0 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) printf '未知参数：%s（可用：--package / --no-self-test / --help）\n' "$arg" >&2; exit 2 ;;
    esac
done

die() { printf '\n构建中止：%s\n' "$1" >&2; exit 1; }

check_environment() {
    [ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上构建，当前系统是 $(uname -s)。"
    local arch
    arch="$(uname -m)"
    if [ "$arch" != "arm64" ]; then
        die "本项目只支持 Apple Silicon（arm64），当前是 $arch。Intel Mac 需把 DEPLOY_TARGET 改成 x86_64-apple-macosx14.0 后自行验证。"
    fi
    local os_major
    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$os_major" -lt 14 ]; then
        die "需要 macOS 14 或更新版本，当前是 $(sw_vers -productVersion)。"
    fi
    if ! command -v swiftc >/dev/null 2>&1; then
        die "找不到 swiftc。先安装 Xcode Command Line Tools：
    xcode-select --install
装完重新运行本脚本（不需要完整 Xcode）。"
    fi
}

compile() {
    printf '编译中…\n'
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
    if ! swiftc -O -target "$DEPLOY_TARGET" -framework AppKit \
        Sources/main.swift Sources/Jelly.swift -o "$BUNDLE/Contents/MacOS/$EXECUTABLE"; then
        die "swiftc 编译失败，请把上面的完整报错贴出来。"
    fi
    for icon in claude-mark gpt-mark gemini-mark; do
        [ -f "Assets/$icon.png" ] || die "缺少 Assets/$icon.png。先运行：python3 Tools/make-icon.py"
        cp "Assets/$icon.png" "$BUNDLE/Contents/Resources/"
    done
    [ -f Assets/AppIcon.icns ] && cp Assets/AppIcon.icns "$BUNDLE/Contents/Resources/"
    cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$EXECUTABLE</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$DISPLAY_NAME</string>
<key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
    # 从下载目录 / iCloud 拷来的文件可能带资源叉或隔离标记，会让签名失败
    xattr -cr "$BUNDLE" 2>/dev/null || true
    codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || die "本地签名失败。"
    # iCloud 同步目录会往 .app 上补 FinderInfo，--strict 会因此报错（签名本身没事）。
    # 清几次，清不掉也不影响运行，只给个提示。
    local strict=0
    for _ in 1 2 3; do
        xattr -cr "$BUNDLE" 2>/dev/null || true
        if codesign --verify --strict "$BUNDLE" >/dev/null 2>&1; then strict=1; break; fi
        sleep 0.2
    done
    codesign --verify "$BUNDLE" >/dev/null 2>&1 || die "本地签名校验失败。"
    if [ "$strict" != "1" ]; then
        printf '提示：目录在 iCloud 同步范围里，FinderInfo 反复被加回来，--strict 校验会报资源叉。\n'
    fi
}

self_test() {
    printf '自检中…\n'
    local out
    if ! out="$("$BUNDLE/Contents/MacOS/$EXECUTABLE" --self-test 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "自检未通过（上面每行 FAIL 都指向具体环节）。"
    fi
    printf '%s\n' "$out" | tail -4
}

package() {
    local base="JellyPet-$VERSION"
    mkdir -p "$DIST"
    rm -f "$DIST/$base.zip" "$DIST/$base.dmg" "$DIST/$base.sha256"
    ditto -c -k --keepParent "$BUNDLE" "$DIST/$base.zip"
    local stage
    stage="$(mktemp -d)"
    cp -R "$BUNDLE" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "$DISPLAY_NAME" -srcfolder "$stage" -ov -format UDZO \
        "$DIST/$base.dmg" || die "生成 dmg 失败。"
    rm -rf "$stage"
    ( cd "$DIST" && shasum -a 256 "$base.zip" "$base.dmg" > "$base.sha256" )
    printf '分发包：\n'
    ls -lh "$DIST" | sed 1d | sed 's/^/  /'
}

check_environment
compile
if [ "$SELF_TEST" = "1" ]; then self_test; fi
if [ "$PACKAGE" = "1" ]; then package; fi
printf '完成：%s\n' "$BUNDLE"
printf '安装：./install.sh（或把 app 拖进「应用程序」）\n'
