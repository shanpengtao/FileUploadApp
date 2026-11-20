#!/bin/bash
# ============================================================
# build_pkg.sh — 将 文件传输助手 构建并打包为可安装的 .pkg
# 用法: bash build_pkg.sh
# ============================================================
set -e

APP_NAME="FileUploadApp"
SCHEME="FileUploadApp"
PROJECT="FileUploadApp.xcodeproj"
BUNDLE_ID="com.58.FileUploadApp"
VERSION="1.0.0"
DISPLAY_NAME="文件传输助手"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
PKG_DIR="$BUILD_DIR/pkg"
OUTPUT_PKG="$BUILD_DIR/${DISPLAY_NAME}_${VERSION}.pkg"

# ---------- 证书与描述文件 ----------
P12_PATH=""
P12_PASSWORD=""   # P12 无密码留空
PROVISION_PATH=""
TEAM_ID=""
SIGN_IDENTITY=""
# mac_dev_universal 是 Development 类型描述文件，搭配 Apple Development 证书
# Xcode 会自动选择匹配 Team 的 Apple Development 证书

# ---------- 公证信息（如需公证，填入 Apple ID 信息） ----------
# NOTARIZE=1 时启用公证，需填写以下三项
NOTARIZE=0
APPLE_ID=""           # Apple ID 邮箱，如 example@58.com
APP_SPECIFIC_PASSWORD="" # App 专用密码，在 https://appleid.apple.com 生成
ASC_PROVIDER="2AYM9C3RH8"  # Team Short Name

echo "========================================"
echo " 构建 $DISPLAY_NAME $VERSION"
echo "========================================"

cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$PKG_DIR/root/Applications"

# ---- Step 0: 准备签名环境 ----
echo "[0/6] 准备签名环境..."
KEYCHAIN="$BUILD_DIR/sign.keychain"
KEYCHAIN_PASSWORD="build$(date +%s)"

# 创建临时 Keychain
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -t 3600 -u "$KEYCHAIN"

# 导入 P12（如果有）
if [ -f "$P12_PATH" ]; then
  if [ -n "$P12_PASSWORD" ]; then
    security import "$P12_PATH" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productsign
  else
    security import "$P12_PATH" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productsign 2>/dev/null || true
  fi
  echo "  ✅ P12 已导入（如失败则使用系统 Keychain 证书）"
else
  echo "  ⚠️ P12 文件不存在，将使用系统 Keychain 中的证书"
fi

# 将临时 Keychain 加入搜索列表，并允许 codesign 访问
security list-keychains -s "$KEYCHAIN" $(security list-keychains | tr -d '"')
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" 2>/dev/null || true

# 验证证书是否可用（检查系统 Keychain + 临时 Keychain）
echo "  当前可用签名证书:"
security find-identity -v -p codesigning 2>/dev/null | head -5 || true

# ---- Step 1: Archive ----
echo "[1/6] Archive..."

# 提取描述文件 UUID，供 xcodebuild 使用
PROVISION_UUID=""
if [ -f "$PROVISION_PATH" ]; then
  PROVISION_UUID=$(security cms -D -i "$PROVISION_PATH" 2>/dev/null | plutil -extract UUID raw - 2>/dev/null || true)
  echo "  描述文件 UUID: $PROVISION_UUID"
  # 将描述文件复制到 xcodebuild 可查找的位置
  PROVISIONS_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$PROVISIONS_DIR"
  cp "$PROVISION_PATH" "$PROVISIONS_DIR/${PROVISION_UUID}.provisionprofile"
  echo "  ✅ 描述文件已安装"
else
  echo "  ⚠️ 描述文件不存在: $PROVISION_PATH"
fi

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="mac_dev_universal" \
  | grep -E "error:|warning:|BUILD|Archive" | grep -v "^$" || true

# ---- Step 2: Export .app ----
echo "[2/6] Export .app..."

cat > "$BUILD_DIR/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGN_IDENTITY</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_ID</key>
        <string>$PROVISION_UUID</string>
    </dict>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  | grep -E "error:|Export" || true

# 自动查找导出目录中第一个 .app
APP_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -name "*.app" | head -1)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "❌ 找不到导出的 .app，请检查 Archive 步骤"
  exit 1
fi
echo "导出应用: $APP_PATH"

# ---- Step 3: 验证 .app 签名 ----
echo "[3/6] 验证签名..."
codesign --verify --verbose=1 "$APP_PATH" 2>&1 | head -3 || true
echo "  签名信息:"
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier" | head -5 || true

# ---- Step 4: 复制到 pkg 根目录 ----
echo "[4/6] 准备 pkg 目录结构..."
cp -R "$APP_PATH" "$PKG_DIR/root/Applications/"

# ---- Step 5: 打包 pkg ----
echo "[5/6] 打包 .pkg..."

# Apple Distribution 证书只能签 .app，不能签 .pkg（需要 Developer ID Installer 证书）
# 所以 pkg 本身不签名，但 .app 内部已由 xcodebuild 签名
pkgbuild \
  --root "$PKG_DIR/root" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --install-location "/" \
  "$OUTPUT_PKG"

echo "  ✅ pkg 已生成（.app 内已签名，.pkg 未签名）"

# ---- Step 6: 公证（可选） ----
if [ "$NOTARIZE" = "1" ]; then
  echo "[6/6] 提交公证..."
  SUBMIT_OUTPUT=$(xcrun notarytool submit "$OUTPUT_PKG" \
    --apple-id "$APPLE_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --team-id "$ASC_PROVIDER" \
    --wait 2>&1 || true)

  echo "$SUBMIT_OUTPUT"

  if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
    echo "  ✅ 公证通过，装订票据..."
    xcrun stapler staple "$OUTPUT_PKG"
    echo "  ✅ 票据已装订"
  else
    echo "  ❌ 公证未通过，请检查日志："
    echo "$SUBMIT_OUTPUT" | grep -i "id:" | head -1
    echo "  查看详情: xcrun notarytool log <submission-id> --apple-id $APPLE_ID"
  fi
else
  echo "[6/6] 跳过公证（NOTARIZE=0），如需公证请设置 NOTARIZE=1 并填写 Apple ID 信息"
fi

# ---- 清理临时 Keychain ----
security delete-keychain "$KEYCHAIN" 2>/dev/null || true

echo ""
echo "========================================"
echo "✅ 打包完成: $OUTPUT_PKG"
echo ""
echo "📌 签名信息:"
echo "  .app 内部已签名，.pkg 未签名（需 Developer ID Installer 证书才能签名 pkg）"
echo ""
if [ "$NOTARIZE" = "1" ]; then
  echo "✅ 已签名 + 公证，接收方可直接双击安装"
else
  echo "📌 接收方安装时需："
  echo "   右键 .pkg → 打开 → 点击「打开」"
  echo "   或终端执行: xattr -cr $(basename "$OUTPUT_PKG")"
fi
echo "========================================"
