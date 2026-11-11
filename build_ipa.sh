#!/usr/bin/env bash
# 出 IPA，两种模式：
#   ./build_ipa.sh unsigned            # 不需要证书，产出未签名 ipa（配合 Sideloadly 自签）
#   ./build_ipa.sh ad-hoc              # 需要证书 + 描述文件
#   TEAM_ID=ABCDE12345 PROFILE="Yabo AdHoc" ./build_ipa.sh ad-hoc
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-unsigned}"
TEAM_ID="${TEAM_ID:-TEAM_ID_PLACEHOLDER}"
PROFILE="${PROFILE:-PROFILE_NAME_PLACEHOLDER}"
BUNDLE_ID="${BUNDLE_ID:-com.yabo.chuanshuo}"

echo "== 0. 环境检查"
command -v xcodebuild >/dev/null || { echo "缺少 Xcode，需要 macOS 或 GitHub Actions 的 macOS runner"; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null && brew install xcodegen || { echo "请先安装 xcodegen"; exit 1; }
fi

echo "== 1. 生成工程"
xcodegen generate --spec project.yml
rm -rf build
mkdir -p build

# ---------- 未签名：谁都能跑 ----------
if [ "$MODE" = "unsigned" ]; then
  echo "== 2. 编译（关闭签名）"
  xcodebuild -project YaboIOS.xcodeproj \
    -scheme YaboIOS \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/dd \
    build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    PROVISIONING_PROFILE_SPECIFIER=""

  APP="build/dd/Build/Products/Release-iphoneos/YaboIOS.app"
  [ -d "$APP" ] || { echo "编译产物不存在：$APP"; exit 1; }

  echo "== 3. 打包未签名 ipa"
  mkdir -p build/Payload
  cp -R "$APP" build/Payload/
  # 去掉可能残留的签名信息
  rm -rf "build/Payload/YaboIOS.app/_CodeSignature" "build/Payload/YaboIOS.app/embedded.mobileprovision"
  ( cd build && zip -qry "YaboIOS-unsigned.ipa" Payload )

  echo "== 4. 产物"
  ls -lh build/YaboIOS-unsigned.ipa
  echo "IPA: $(pwd)/build/YaboIOS-unsigned.ipa"
  echo "接下来：Windows 装 Sideloadly，拖进去，用 Apple ID 自签安装"
  exit 0
fi

# ---------- 已签名 ----------
echo "== 2. 写入 ExportOptions"
python3 - "$MODE" "$TEAM_ID" "$PROFILE" "$BUNDLE_ID" <<'PY'
import plistlib, sys
mode, team, profile, bundle = sys.argv[1:5]
d = {
    "method": mode,
    "signingStyle": "manual",
    "teamID": team,
    "provisioningProfiles": {bundle: profile},
    "compileBitcode": False,
    "stripSwiftSymbols": True,
    "thinning": "<none>",
    "destination": "export",
}
if mode in ("ad-hoc", "app-store"):
    d["uploadSymbols"] = False
open("ExportOptions.plist", "wb").write(plistlib.dumps(d))
print("method =", mode, "team =", team)
PY

echo "== 3. Archive"
xcodebuild -project YaboIOS.xcodeproj \
  -scheme YaboIOS \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/YaboIOS.xcarchive \
  -allowProvisioningUpdates \
  archive \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"

echo "== 4. Export IPA"
xcodebuild -exportArchive \
  -archivePath build/YaboIOS.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates

echo "== 5. 产物"
ls -lh build/ipa/
IPA=$(ls build/ipa/*.ipa 2>/dev/null | head -1 || true)
[ -n "$IPA" ] && echo "IPA: $IPA" && du -h "$IPA"
