#!/bin/zsh
# 量測整個 App：啟動到第一個畫面、閒置時的 CPU 與記憶體、App 的大小，
# 並和空白的 SwiftUI App（Tools/emptyshell）比較（DESIGN.md 9.8 節）。
#
#   Scripts/measure-app.sh [啟動次數，預設 20]
#
# - 兩個 App 都隱藏執行（不顯示視窗、不搶焦點），用暫存的工作目錄與 Library，不讀鑰匙圈，不花 API 費用。
#   隱藏的視窗不會真的畫到螢幕上，所以量到的是「第一個畫面準備好」的時間；兩個 App 用同樣的方式量，比值是公平的。
# - 啟動時間取中位數（第一輪當暖身，不計）。預算在 Benchmarks/perf-budgets.json，
#   超過預算時以非零的狀態結束。共用的慢機器可以用 THUNDER_PERF_FACTOR 放寬，和 make test-perf 一樣。
# - 錄音中的 CPU 會花 API 費用，不在這裡量。
set -eu
cd "$(dirname "$0")/.."
runs=${1:-20}
work=$(mktemp -d -t thunderflow-measure)
trap 'pkill -f -- "-workingPath $work/" 2>/dev/null; rm -rf "$work"' EXIT

echo "打包 ThunderFlow.app 與對照用的 EmptyShell.app……"
Scripts/build-app.sh >/dev/null
swift build --package-path Tools/emptyshell -c release >/dev/null
empty=build/EmptyShell.app
rm -rf "$empty"
mkdir -p "$empty/Contents/MacOS"
cp "$(swift build --package-path Tools/emptyshell -c release --show-bin-path)/EmptyShell" "$empty/Contents/MacOS/EmptyShell"
cp Tools/emptyshell/Info.plist "$empty/Contents/Info.plist"
codesign --force --options runtime --sign - "$empty" 2>/dev/null

# 啟動到第一個畫面：兩個 App 交錯執行，抵銷機器狀態的變化
echo "啟動 ${runs} 輪……"
for i in $(seq 0 "$runs"); do
    for name in EmptyShell ThunderFlow; do
        open -W -n -g -j "build/${name}.app" --stdout "$work/launch.${name}.${i}" --args \
            -reportLaunch YES -quitAfterLaunch YES -workingPath "$work/w${i}/" -libraryPath "$work/lib"
    done
done

# 閒置：啟動之後等 10 秒穩定下來，再看 30 秒內的 CPU 與喚醒次數，最後看記憶體
idle() {
    local name=$1 tag="$work/idle-${1}/"
    open -n -g -j "build/${name}.app" --args -workingPath "$tag" -libraryPath "$work/lib"
    sleep 10
    local pid
    pid=$(pgrep -n -f -- "-workingPath $tag")
    top -l 2 -s 30 -pid "$pid" -stats cpu,idlew | tail -1 > "$work/idle.${name}.top"
    footprint -p "$pid" 2>/dev/null | grep -o 'Footprint: [0-9.]* [KMG]B' > "$work/idle.${name}.footprint" || true
    kill "$pid"
}
echo "閒置量測（每個 App 約 45 秒）……"
idle EmptyShell
idle ThunderFlow

du -sk build/ThunderFlow.app | cut -f1 > "$work/bundle.kb"

python3 - "$work" "$runs" <<'PY'
import glob, json, os, re, statistics, sys
work, runs = sys.argv[1], int(sys.argv[2])
budgets = {k: v["value"] for k, v in json.load(open("Benchmarks/perf-budgets.json"))["budgets"].items()}
factor = float(os.environ.get("THUNDER_PERF_FACTOR", "1"))

def launches(name, key="firstFrame"):
    values = []
    for i in range(1, runs + 1):  # 第 0 輪是暖身
        text = open(f"{work}/launch.{name}.{i}").read()
        match = re.search(rf"launch\.{key}\.ms ([0-9.]+)", text)
        if match: values.append(float(match.group(1)))
    return values

def idle(name):
    cpu, wakeups = open(f"{work}/idle.{name}.top").read().split()[:2]
    footprint = open(f"{work}/idle.{name}.footprint").read().split()
    size = float(footprint[1]) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[footprint[2]]
    return float(cpu), int(wakeups.rstrip("+-")) / 30, size

empty, app = launches("EmptyShell"), launches("ThunderFlow")
if len(app) < runs or len(empty) < runs:
    sys.exit(f"有幾輪沒有回報啟動時間（ThunderFlow {len(app)}／{runs}，EmptyShell {len(empty)}／{runs}）")
empty_cpu, empty_wakeups, empty_mb = idle("EmptyShell")
app_cpu, app_wakeups, app_mb = idle("ThunderFlow")
bundle_mb = int(open(f"{work}/bundle.kb").read()) / 1024
launch, baseline = statistics.median(app), statistics.median(empty)

rows = [
    ("啟動到第一個畫面（中位數）", f"{launch:.0f} ms", "app.launch.firstFrame.milliseconds.max", launch, "ms"),
    ("相對於空白的 App", f"{launch / baseline:.2f} 倍（空白的 App {baseline:.0f} ms）", "app.launch.vsEmptyShell.ratio.max", launch / baseline, "倍"),
    ("閒置時的 CPU", f"{app_cpu:.1f}%（空白的 App {empty_cpu:.1f}%）", "app.idle.cpuPercent.max", app_cpu, "%"),
    ("閒置時的記憶體，比空白的 App 多", f"{app_mb - empty_mb:.1f} MB（{app_mb:.1f} 對 {empty_mb:.1f} MB）", "app.idle.footprintOverEmptyShell.megabytes.max", app_mb - empty_mb, "MB"),
    ("App 大小", f"{bundle_mb:.1f} MB", "app.bundleSize.megabytes.max", bundle_mb, "MB"),
]
failed = False
print()
for label, shown, key, value, unit in rows:
    limit = budgets[key] * factor
    ok = value <= limit
    failed |= not ok
    print(f"{'通過' if ok else '超過'}  {label}：{shown}　預算 {limit:g} {unit}")
print(f"參考  閒置時每秒被喚醒 {app_wakeups:.1f} 次（空白的 App {empty_wakeups:.1f} 次）")
print(f"參考  啟動時間的分布：ThunderFlow {min(app):.0f}–{max(app):.0f} ms，空白的 App {min(empty):.0f}–{max(empty):.0f} ms")
app_init, empty_init = launches("ThunderFlow", "appInit"), launches("EmptyShell", "appInit")
if app_init and empty_init:
    a, e = statistics.median(app_init), statistics.median(empty_init)
    print(f"參考  其中載入程式到 App 初始化：ThunderFlow {a:.0f} ms，空白的 App {e:.0f} ms；"
          f"初始化到第一個畫面：ThunderFlow {launch - a:.0f} ms，空白的 App {baseline - e:.0f} ms")
sys.exit(1 if failed else 0)
PY
