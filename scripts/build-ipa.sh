#!/usr/bin/env bash
# 本地构建 unsigned IPA（需 macOS + Xcode；CI 走 .github/workflows/build-ios.yml）
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 同步前端"
node scripts/sync-web.js

echo "==> 生成 iOS 工程"
if [ ! -d ios ]; then
  npx cap add ios
fi

echo "==> 同步到 iOS 工程"
npx cap sync ios

echo "==> ATS 例外（允许 http 内网 NAS）"
plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads": true}' ios/App/App/Info.plist || true
plutil -insert NSAppTransportSecurity.NSAllowsLocalNetworking -bool true ios/App/App/Info.plist || true

echo "==> Archive（不签名）"
xcodebuild -workspace ios/App/App.xcworkspace \
  -scheme App -configuration Release \
  -destination generic/platform=iOS \
  -archivePath build/App.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  archive

echo "==> 导出 unsigned IPA"
rm -rf build/ipa && mkdir -p build/ipa
xcodebuild -exportArchive -archivePath build/App.xcarchive \
  -exportPath build/ipa -exportOptionsPlist exportOptions.plist \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

echo "==> 产物"
ls -la build/ipa/
