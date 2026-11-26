#!/bin/sh
# iPhone 版「過去錄音」的畫面檢查（DESIGN.md 5.10 節，D38）：在看不到的模擬器上（不開 Simulator 的視窗），
# 用合成的場次當 Library，存三張截圖：清單（library.png）、摘要（summary.png）、逐字稿（transcript.png），
# 並印出讀到的內容。不連線、不需要 Key、不花費用。
# 場次用 make phone-selftest 交出來的那一場（合成語音），加上一份假的摘要：要先跑過 make phone-selftest。
#
#   Scripts/phone-library-check.sh <輸出資料夾>
#   THUNDERFLOW_SIMULATOR=<UDID> 指定模擬器；預設是第一台 iOS 26 以上的 iPhone 模擬器。
set -eu

out="${1:?用法：Scripts/phone-library-check.sh <輸出資料夾>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/phone-dd"
bundle="io.github.ruan330.thunderflow"
source="$(ls -d "$root"/build/phone-selftest/inbox/*/ 2>/dev/null | head -1)"
[ -n "$source" ] || { echo "先跑 make phone-selftest：要用它交出來的那一場當 Library 裡的場次" >&2; exit 1; }
mkdir -p "$out"

xcodebuild -project "$root/iOS/ThunderFlowPhone.xcodeproj" -scheme ThunderFlowPhone \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" -quiet build
app="$derived/Build/Products/Debug-iphonesimulator/ThunderFlowPhone.app"

sim="${THUNDERFLOW_SIMULATOR:-$(xcrun simctl list devices available | awk '
    /^-- iOS / { split($3, v, "."); ok = (v[1] + 0 >= 26); next }
    /^-- / { ok = 0; next }
    ok && /iPhone/ { match($0, /[0-9A-F-]{36}/); print substr($0, RSTART, RLENGTH); exit }')}"
[ -n "$sim" ] || { echo "找不到 iOS 26 以上的 iPhone 模擬器" >&2; exit 1; }

xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl install "$sim" "$app"
data="$(xcrun simctl get_app_container "$sim" "$bundle" data)"
library="$data/tmp/library"
rm -rf "$library"
mkdir -p "$library"
session="$library/2026-12-02 1030 Building Agents with Bedrock AgentCore"
cp -R "$source" "$session"
# 變成 Mac 處理好的樣子：完成、有標題、有摘要
python3 -I - "$session" <<'PY'
import json, pathlib, sys
hidden = pathlib.Path(sys.argv[1]) / ".thunderflow"
meta = json.loads((hidden / "session.json").read_text())
meta["state"] = "complete"
meta["title"] = "Building Agents with Bedrock AgentCore"
meta["completedSteps"] = ["blocks", "transcript", "audio", "publish", "summary"]
(hidden / "session.json").write_text(json.dumps(meta, ensure_ascii=False))
summary = {
    "title": "Building Agents with Bedrock AgentCore",
    "one_liner": "介紹 Amazon Bedrock AgentCore 的三個核心元件，以及怎麼用它們把 agent 放上正式環境。",
    "key_points": ["AgentCore 有 runtime、gateway 與記憶體三個核心元件", "每個工作階段在獨立的 microVM 中執行，最長 8 小時"],
    "chapters": [
        {"start_sec": 0, "title": "AgentCore 的核心元件", "summary": "runtime、gateway 與記憶體各自負責什麼。"},
        {"start_sec": 15, "title": "隔離與規模", "summary": "microVM 的隔離方式與客戶的使用規模。"},
    ],
    "glossary": [{"en": "runtime", "zh": "執行環境"}, {"en": "gateway", "zh": "閘道"}],
    "action_items": ["試用 AgentCore Runtime 的範例"],
}
(hidden / "summary.json").write_text(json.dumps(summary, ensure_ascii=False))
(hidden / "handoff.json").unlink(missing_ok=True)
PY

cleanup() { xcrun simctl shutdown "$sim" 2>/dev/null || true; }
trap cleanup EXIT

# 打開一次 App、在畫面穩定之後截圖。$1：截圖名稱；$2：打開第一場的哪一頁（空的是停在清單）
shot() {
    (
        perl -e 'select(undef, undef, undef, 5)'
        xcrun simctl io "$sim" screenshot "$out/$1.png" >/dev/null 2>&1
    ) &
    shooter=$!
    if [ -n "$2" ]; then
        xcrun simctl launch --console --terminate-running-process "$sim" "$bundle" \
            -selfTestLibrary "$library" -selfTestLibraryOpen "$2" -selfTestQuit YES 2>&1 | grep -E "^library" || true
    else
        xcrun simctl launch --console --terminate-running-process "$sim" "$bundle" \
            -selfTestLibrary "$library" -selfTestQuit YES 2>&1 | grep -E "^library" | tee "$out/library.txt" || true
    fi
    wait "$shooter" 2>/dev/null || true
}
# 清單放最後：模擬器剛開機時第一次啟動 App 比較慢
shot summary summary
shot transcript transcript
shot library ""
echo "截圖：$out/library.png、summary.png、transcript.png"
