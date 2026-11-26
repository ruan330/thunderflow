#!/bin/sh
# iPhone 版的自我檢查（DESIGN.md 5.10 節，D36）：在看不到的模擬器上（不開 Simulator 的視窗）用音檔跑一整場
# （開始、中間標記一次、停止、交接），印出結果，並在錄到四分之三時存一張截圖。會連線，30 秒約 US$0.01。
# 交接用 App 自己資料夾裡的一個收件匣（`-selfTestInbox`），跑完複製到 <輸出資料夾>/inbox：
# 可以再用隱藏的 Mac 版（`-inboxPath`）收進來，檢查整條路（CLAUDE.md）。
#
# Key 經由 App 自己資料夾裡的 FIFO 傳進去：不寫進檔案、不出現在命令列（CLAUDE.md）。
#
#   Scripts/phone-selftest.sh <輸出資料夾> [秒數]
#   THUNDERFLOW_SIMULATOR=<UDID> 指定模擬器；預設是第一台 iOS 26 以上的 iPhone 模擬器。
set -eu

out="${1:?用法：Scripts/phone-selftest.sh <輸出資料夾> [秒數]}"
seconds="${2:-30}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/phone-dd"
bundle="io.github.ruan330.thunderflow"
mkdir -p "$out"

xcodebuild -project "$root/iOS/ThunderFlowPhone.xcodeproj" -scheme ThunderFlowPhone \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" -quiet build
app="$derived/Build/Products/Debug-iphonesimulator/ThunderFlowPhone.app"

# 第一台 iOS 26 以上的 iPhone 模擬器
sim="${THUNDERFLOW_SIMULATOR:-$(xcrun simctl list devices available | awk '
    /^-- iOS / { split($3, v, "."); ok = (v[1] + 0 >= 26); next }
    /^-- / { ok = 0; next }
    ok && /iPhone/ { match($0, /[0-9A-F-]{36}/); print substr($0, RSTART, RLENGTH); exit }')}"
[ -n "$sim" ] || { echo "找不到 iOS 26 以上的 iPhone 模擬器" >&2; exit 1; }

xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
data="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
mkdir -p "$data/tmp"
cp "$root/Benchmarks/data/keynote.wav" "$data/tmp/keynote.wav"
fifo="$data/tmp/key"
rm -f "$fifo"
mkfifo -m 600 "$fifo"
inbox="$data/tmp/inbox"
rm -rf "$inbox" "$out/inbox"
mkdir -p "$inbox"

writer=""
shooter=""
cleanup() {
    [ -n "$writer" ] && kill "$writer" 2>/dev/null || true
    [ -n "$shooter" ] && kill "$shooter" 2>/dev/null || true
    rm -f "$fifo"
    xcrun simctl shutdown "$sim" 2>/dev/null || true
}
trap cleanup EXIT

security find-generic-password -a "$USER" -s thunderflow-openai-dev -w > "$fifo" &
writer=$!
(
    perl -e "select(undef, undef, undef, $seconds * 0.75 + 2)"
    xcrun simctl io "$sim" screenshot "$out/recording.png" >/dev/null 2>&1
) &
shooter=$!

xcrun simctl launch --console --terminate-running-process "$sim" "$bundle" \
    -selfTestFile "$data/tmp/keynote.wav" -selfTestSeconds "$seconds" -apiKeyFIFO "$fifo" -selfTestInbox "$inbox" \
    -selfTestQuit YES 2>&1 |
    grep -E "^selfTest" | tee "$out/selftest.txt"
wait "$shooter" 2>/dev/null || true
shooter=""
cp -R "$inbox" "$out/inbox"
echo "收件匣：$(find "$out/inbox" -name handoff.json | wc -l | tr -d ' ') 場（$out/inbox）"
echo "截圖：$out/recording.png"
