#!/usr/bin/env bash
# 上傳到 TestFlight：Release 封存 → 用 App Store Connect API key 簽名並上傳。
# 需要：付費的 Apple Developer 帳號、Xcode 26 以上（App Store Connect 只收 iOS 26 SDK 建的版本）。
#
# 一次性設定（在 App Store Connect → 使用者與存取權限 → 整合 → App Store Connect API 建一把「App 管理」權限的 key）：
#   1. 下載的 AuthKey_XXXXXXXXXX.p8 放到 ~/.appstoreconnect/private_keys/（只能下載一次，不要放進 repo）
#   2. 在 ~/.zshrc 或 ~/.bash_profile 設：
#        export ASC_KEY_ID=XXXXXXXXXX        # key 的 ID
#        export ASC_ISSUER_ID=xxxxxxxx-...   # 頁面上方的 Issuer ID
#        export ASC_TEAM_ID=XXXXXXXXXX       # 開發者帳號的 Team ID（developer.apple.com → Membership）
#   3. 在 App Store Connect 先建好 App（Bundle ID：io.rookielab.app）
# 用法：ios/testflight.sh            版本號照 project.yml，build 號自動用時間
set -euo pipefail
cd "$(dirname "$0")"

: "${ASC_KEY_ID:?先設 ASC_KEY_ID（見檔案開頭說明）}"
: "${ASC_ISSUER_ID:?先設 ASC_ISSUER_ID}"
: "${ASC_TEAM_ID:?先設 ASC_TEAM_ID（付費帳號的 Team ID，不是免費的 Personal Team）}"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[[ -f "$KEY" ]] || { echo "找不到 $KEY"; exit 1; }

XCODE_MAJOR=$(xcodebuild -version | awk '/^Xcode/ {split($2, v, "."); print v[1]}')
(( XCODE_MAJOR >= 26 )) || { echo "要 Xcode 26 以上才能上傳（現在是 $(xcodebuild -version | head -1)）"; exit 1; }

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet

BUILD=$(date +%Y%m%d%H%M)
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "▶ 封存（build ${BUILD}）"
xcodebuild -project RookieLab.xcodeproj -scheme RookieLab -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/RookieLab.xcarchive \
  DEVELOPMENT_TEAM="$ASC_TEAM_ID" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD" \
  "${AUTH[@]}" -quiet archive

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${ASC_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST

echo "▶ 上傳到 App Store Connect"
xcodebuild -exportArchive -archivePath build/RookieLab.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}"

echo "上傳好了。App Store Connect 處理完（約 10–30 分鐘）會出現在 TestFlight，自己的帳號加進「內部測試」就能在手機的 TestFlight App 安裝。"
