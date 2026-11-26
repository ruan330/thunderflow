#!/bin/sh
# 把 iPhone 版（Release）裝到用線接在這台 Mac 上的 iPhone（DESIGN.md 5.10 節，D36）。
#
# 需要（第一次）：
#   1. iOS/Local.xcconfig 寫著 `DEVELOPMENT_TEAM = <團隊 ID>`（不進 git；簽章團隊一律由負責人明確指定，CLAUDE.md）。
#   2. Xcode → Settings → Accounts 登入了這個團隊的 Apple ID（xcodebuild 用它建立描述檔、登記這支 iPhone）。
#   3. iPhone 用線接上、按過「信任」，並打開「設定 → 隱私權與安全性 → 開發者模式」。
#
#   Scripts/phone-install.sh            裝到第一支接著的 iPhone
#   THUNDERFLOW_DEVICE=<識別碼> 指定哪一支（`xcrun devicectl list devices` 的 Identifier）
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="io.github.ruan330.thunderflow"
derived="$root/build/phone-device"

if ! grep -q '^ *DEVELOPMENT_TEAM *= *[A-Z0-9]\{10\}' "$root/iOS/Local.xcconfig" 2>/dev/null; then
    echo "缺少 iOS/Local.xcconfig：請寫一行「DEVELOPMENT_TEAM = 你的團隊 ID」（10 個英數字，Apple Developer 網站的 Membership 頁）。" >&2
    exit 1
fi

json="$(mktemp -t thunderflow-devices)"
trap 'rm -f "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null
device="${THUNDERFLOW_DEVICE:-$(python3 -I - "$json" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPhone" and hw.get("reality") == "physical":
        print(d.get("identifier", ""))
        break
EOF
)}"
if [ -z "$device" ]; then
    echo "找不到接著的 iPhone：請用線接上、在手機上按「信任」，並打開開發者模式。" >&2
    exit 1
fi

xcodebuild -project "$root/iOS/ThunderFlowPhone.xcodeproj" -scheme ThunderFlowPhone -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$derived" -allowProvisioningUpdates -quiet build
app="$derived/Build/Products/Release-iphoneos/ThunderFlowPhone.app"
codesign --verify --deep --strict "$app"
xcrun devicectl device install app --device "$device" "$app"
echo "已經裝到 iPhone（$bundle）。第一次打開時請允許麥克風。"
