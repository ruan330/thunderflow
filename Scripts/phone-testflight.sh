#!/bin/sh
# 把 iPhone 版（Release）上傳到 App Store Connect，給 TestFlight 用（DESIGN.md 5.10 節）。
# 之後更新不用接線：上傳新版，手機在 TestFlight 按「更新」。每個版本可以用 90 天。
#
# 需要（第一次）：
#   1. iOS/Local.xcconfig 寫著 `DEVELOPMENT_TEAM = <團隊 ID>`（和 phone-install 一樣；不進 git）。
#   2. Xcode → Settings → Accounts 登入了這個團隊的 Apple ID（xcodebuild 用它簽章、上傳）。
#   3. App Store Connect 裡已經有這個 App，「套件識別碼」是 io.github.ruan330.thunderflow：建立時在下拉選單選
#      「XC io github ruan330 thunderflow - io.github.ruan330.thunderflow」（Xcode 自動註冊的），不要另外註冊新的。
#      選錯時上傳會說找不到這個 App；還沒上傳過任何版本之前，可以在「App 資訊」裡改回來。
#
# 版號（CFBundleVersion）用上傳的時間（例如 202611252130），每次都比上一次大；給人看的版本是專案裡的 MARKETING_VERSION。
#
#   Scripts/phone-testflight.sh
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
team="$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\).*/\1/p' "$root/iOS/Local.xcconfig" 2>/dev/null | head -1)"
if [ -z "$team" ]; then
    echo "缺少 iOS/Local.xcconfig：請寫一行「DEVELOPMENT_TEAM = 你的團隊 ID」（10 個英數字，Apple Developer 網站的 Membership 頁）。" >&2
    exit 1
fi

out="$root/build/phone-testflight"
rm -rf "$out"
mkdir -p "$out"
build="$(date +%Y%m%d%H%M)"

xcodebuild -project "$root/iOS/ThunderFlowPhone.xcodeproj" -scheme ThunderFlowPhone -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$out/ThunderFlowPhone.xcarchive" \
    -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" -quiet archive

# 團隊 ID 只寫進 build/（不進 git）
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${team}</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$out/ThunderFlowPhone.xcarchive" -exportOptionsPlist "$out/ExportOptions.plist" \
    -exportPath "$out/export" -allowProvisioningUpdates
echo "已經上傳（版號 ${build}）。App Store Connect 處理完（通常 5–15 分鐘）之後，TestFlight 裡就會出現這一版。"
