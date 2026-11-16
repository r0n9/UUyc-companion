#!/bin/zsh
# 构建应用并生成拖拽安装 DMG；签名配置沿用 build-app.sh。
# 无证书时：SIGN_IDENTITY=- scripts/build-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" != 0 ]]; then
  echo '用法：SIGN_IDENTITY=- scripts/build-dmg.sh' >&2
  exit 2
fi

scripts/build-app.sh
APP_NAME="UUyc companion"
APP="build/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :UUDisplayReleaseVersion' "$APP/Contents/Info.plist")"
IMAGE_NAME="UUyc-companion-$VERSION.dmg"
DMG_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$DMG_WORK_DIR"' EXIT
PAYLOAD_DIR="$DMG_WORK_DIR/payload"
mkdir -p "$PAYLOAD_DIR" dist
ditto "$APP" "$PAYLOAD_DIR/$APP_NAME.app"
ln -s /Applications "$PAYLOAD_DIR/Applications"
cat > "$PAYLOAD_DIR/安装说明.txt" <<TEXT
UUyc companion $VERSION（UU远程伴侣）

当前维护者：r0n9。基于 AoyamaShou 的 UUyc companion 原项目分叉维护。

将「UUyc companion.app」拖到「Applications」文件夹，然后从应用程序中打开。
首次启动时按引导授予辅助功能权限，并填写设备分辨率。

此构建未经过 Apple 公证。若系统阻止打开，请到「系统设置 → 隐私与安全性」允许打开。
TEXT
codesign --verify --strict --deep "$PAYLOAD_DIR/$APP_NAME.app"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$PAYLOAD_DIR" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_WORK_DIR/$IMAGE_NAME"
hdiutil verify "$DMG_WORK_DIR/$IMAGE_NAME"
mv -f "$DMG_WORK_DIR/$IMAGE_NAME" "dist/$IMAGE_NAME"
(cd dist && shasum -a 256 "$IMAGE_NAME" > "$IMAGE_NAME.sha256")
echo "✅ 已生成 dist/$IMAGE_NAME"
