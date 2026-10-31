#!/usr/bin/env bash
# 裝到自己的 iPhone：Release 建置（引擎快 3 倍多）、自動簽名、安裝並打開。
# 用法：ios/device.sh            裝到第一台連著的 iPhone
#       ios/device.sh test       先在模擬器跑完測試（含真實帳號），過了才裝
# 免費 Personal Team 的簽名 7 天過期，過期再跑一次就好。
set -euo pipefail
cd "$(dirname "$0")"
TEAM="${TEAM:-L756RGRFW2}"
# 個人測試用另一個 Bundle ID：正式的 io.rookielab.app 留給之後上架的開發者帳號註冊
# 付費團隊用正式的 Bundle ID（io.rookielab.app.dev 被舊的免費帳號註冊走了，換不了團隊）
BUNDLE_ID="${BUNDLE_ID:-io.rookielab.app}"
ACCOUNT="${TEST_ACCOUNT:-chesscom:rookielab-io}"

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet

if [[ "${1:-}" == "test" ]]; then
  echo "▶ 模擬器測試（帳號 ${ACCOUNT}）"
  TEST_ACCOUNT="$ACCOUNT" xcodebuild test -project RookieLab.xcodeproj -scheme RookieLab \
    -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build -quiet \
    -skip-testing:RookieLabTests/GradingTests/testEngineSpeed -skip-testing:RookieLabTests/PerfTests -skip-testing:RookieLabTests/LessonLineTests -skip-testing:RookieLabTests/LessonLineTests
fi

# 只挑實體手機（Xcode 27 的清單也列出模擬器）；取 UDID 那一欄
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available|connected/ && !/unavailable/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]+/) {print $i; exit}}')
USB=$(command -v idevice_id >/dev/null && idevice_id -l 2>/dev/null | head -1 || true)
if [[ -z "$DEVICE" && -z "$USB" ]]; then
  echo "找不到連著的 iPhone：用線接上、解鎖、按「信任這部電腦」，並在 設定→隱私權與安全性→開發者模式 打開。"
  xcrun devicectl list devices
  exit 1
fi

echo "▶ 建置（Release，Team ${TEAM}）"
xcodebuild -project RookieLab.xcodeproj -scheme RookieLab -configuration Release \
  -destination "${DEVICE:+id=$DEVICE}" \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic BUNDLE_BASE="$BUNDLE_ID" -quiet build \
  || { echo "簽名失敗多半是 Xcode 沒登入：Xcode → Settings → Accounts → + 登入 Apple ID。"; exit 1; }

APP=build/Build/Products/Release-iphoneos/RookieLab.app
echo "▶ 安裝"
# Xcode 版本比手機的 iOS 舊（例如 Xcode 16 + iOS 26）時 devicectl 掛不上開發者映像，
# 改用 libimobiledevice 直接走 USB 安裝（brew install libimobiledevice ideviceinstaller）
if [[ -n "$DEVICE" ]] && xcrun devicectl device install app --device "$DEVICE" "$APP" 2>/dev/null; then
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
else
  command -v ideviceinstaller >/dev/null || brew install libimobiledevice ideviceinstaller
  [[ -n "$USB" ]] || { echo "要用線接著才能裝（USB）"; exit 1; }
  rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R "$APP" build/ipa/Payload/
  (cd build/ipa && zip -qry ../RookieLab-dev.ipa Payload)
  ideviceinstaller -u "$USB" install build/RookieLab-dev.ipa
fi
EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)
echo "裝好了${EXP:+，簽名到 $EXP 過期（到時再跑一次 ios/device.sh）}。"
echo "第一次打開若顯示「不受信任的開發者」：設定→一般→VPN 與裝置管理→信任 Apple Development。"
