#!/bin/zsh
# 量測錄音與即時翻譯中的 CPU（DESIGN.md 9.8 節的 `app.recording.cpuPercent`）：用音檔當來源跑一場自我檢查，
# 錄音中第 10–40 秒的平均 CPU 不可以超過預算。
#
#   Scripts/measure-recording.sh [--hidden] [--runs N]
#
# - 預設顯示視窗（不搶焦點）：使用者實際看到的情況，字幕要真的畫出來，CPU 才算得準。
#   `--hidden` 隱藏執行，不會出現視窗，但隱藏的視窗不會真的畫，量到的數字比實際低，只能拿來快速比較。
# - 會連線、花 API 費用：每一輪約 50 秒的音訊，不到 US$0.02。Key 從鑰匙圈的開發用項目讀
#   （`thunderflow-openai-dev`，見 CLAUDE.md），經由 FIFO 交給 App，不落地、不碰 App 自己的鑰匙圈項目。
# - 用暫存的工作目錄與 Library，不碰使用者的資料。音檔是 `Benchmarks/data/keynote.wav`（`thunderbench synth` 產生）。
# - 跑好幾輪時取中位數。超過預算時以非零的狀態結束；共用的慢機器可以用 THUNDER_PERF_FACTOR 放寬，和 make test-perf 一樣。
# - 同時印出參考數字：主執行緒的 CPU、錄音中主執行緒最長的卡頓（`ui.mainThreadHitch`，只有顯示視窗時才準）。
set -eu
cd "$(dirname "$0")/.."
hidden=NO
runs=1
while (( $# )); do
    case $1 in
        --hidden) hidden=YES ;;
        --runs) shift; runs=$1 ;;
        *) echo "用法：Scripts/measure-recording.sh [--hidden] [--runs N]" >&2; exit 2 ;;
    esac
    shift
done
audio="$PWD/Benchmarks/data/keynote.wav"
[[ -f $audio ]] || { echo "找不到 $audio：先用 thunderbench synth 產生（見 CLAUDE.md）" >&2; exit 2 }
security find-generic-password -a "$USER" -s thunderflow-openai-dev >/dev/null 2>&1 \
    || { echo "鑰匙圈裡沒有開發用的 Key（帳號 \$USER、服務 thunderflow-openai-dev），見 CLAUDE.md" >&2; exit 2 }

work=$(mktemp -d -t thunderflow-recording)
trap 'pkill -f -- "-workingPath $work/" 2>/dev/null; rm -rf "$work"' EXIT

echo "打包 ThunderFlow.app……"
Scripts/build-app.sh >/dev/null

python3 - "$work" "$audio" "$hidden" "$runs" <<'PY'
import json, os, re, statistics, subprocess, sys, time
work, audio, hidden, runs = sys.argv[1], sys.argv[2], sys.argv[3] == "YES", int(sys.argv[4])
budget = json.load(open("Benchmarks/perf-budgets.json"))["budgets"]["app.recording.cpuPercent.max"]["value"]
factor = float(os.environ.get("THUNDER_PERF_FACTOR", "1"))
window = (10.0, 40.0)   # 錄音開始後的第幾秒到第幾秒：避開開始時的連線與第一段字幕
seconds = 50            # 錄音的長度

def seconds_of(value):
    total = 0.0
    for part in value.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total

def cpu_seconds(pid):
    """整個程序與主執行緒到目前為止用掉的 CPU 秒數。"""
    process = subprocess.run(["ps", "-o", "time=", "-p", pid], capture_output=True, text=True).stdout.strip()
    rows = subprocess.run(["ps", "-M", "-p", pid], capture_output=True, text=True).stdout.splitlines()[1:]
    # 第一列是主執行緒，開頭多了使用者名稱，系統時間與使用者時間在第 7、8 欄
    fields = rows[0].split() if rows else []
    main = seconds_of(fields[6]) + seconds_of(fields[7]) if len(fields) > 7 else float("nan")
    return seconds_of(process), main

def run(index):
    folder = os.path.join(work, f"run{index}")
    os.makedirs(folder)
    key, out = os.path.join(folder, "key"), os.path.join(folder, "out")
    os.mkfifo(key, 0o600)
    subprocess.Popen(["/bin/sh", "-c", 'security find-generic-password -a "$USER" -s thunderflow-openai-dev -w > "$0"', key])
    args = ["open", "-W", "-n", "-g"] + (["-j"] if hidden else []) + [
        "build/ThunderFlow.app", "--stdin", key, "--stdout", out, "--stderr", os.path.join(folder, "err"), "--args",
        "-ApplePersistenceIgnoreState", "YES", "-apiKeyFromStdin", "YES", "-reportPerf", "YES",
        "-selfTestFile", audio, "-selfTestSeconds", str(seconds), "-selfTestQuit", "YES",
        "-workingPath", os.path.join(folder, "working") + "/", "-libraryPath", os.path.join(folder, "lib")]
    app = subprocess.Popen(args)
    text = lambda: open(out).read() if os.path.exists(out) else ""
    deadline = time.time() + 60
    while time.time() < deadline and "selfTest: started" not in text():
        time.sleep(0.05)
    started = time.time()
    if "state=recording" not in text():
        app.wait()
        sys.exit("沒有開始錄音：" + (text().splitlines() or ["沒有任何輸出"])[0][:200])
    found = subprocess.run(["pgrep", "-n", "-f", "--", "-workingPath " + os.path.join(folder, "working") + "/"],
                           capture_output=True, text=True).stdout.split()
    if not found:
        sys.exit("找不到 App 的程序")
    pid = found[0]
    time.sleep(max(0, window[0] - (time.time() - started)))
    (cpu0, main0), t0 = cpu_seconds(pid), time.time()
    time.sleep(max(0, window[1] - (time.time() - started)))
    (cpu1, main1), t1 = cpu_seconds(pid), time.time()
    app.wait()
    output = text()
    if "selfTest: done" not in output:
        sys.exit("自我檢查沒有跑完：" + output[-300:])
    hitch = re.search(r"perf\.mainThreadHitch\.ms ([0-9.]+)", output)
    return (cpu1 - cpu0) / (t1 - t0) * 100, (main1 - main0) / (t1 - t0) * 100, float(hitch.group(1)) if hitch else None

mode = "隱藏執行（數字比實際低，只能拿來比較）" if hidden else "顯示視窗"
print(f"錄音 {seconds} 秒、量第 {window[0]:.0f}–{window[1]:.0f} 秒，共 {runs} 輪，{mode}……")
results = []
for index in range(runs):
    cpu, main, hitch = run(index)
    results.append((cpu, main, hitch))
    print(f"  第 {index + 1} 輪：CPU {cpu:.1f}%，主執行緒 {main:.1f}%" + (f"，最長的卡頓 {hitch:.0f} ms" if hitch is not None else ""))

cpu = statistics.median(r[0] for r in results)
main = statistics.median(r[1] for r in results)
limit = budget * factor
ok = cpu <= limit
print()
print(f"{'通過' if ok else '超過'}  錄音與即時翻譯中的 CPU（單核，中位數）：{cpu:.1f}%　預算 {limit:g}%")
print(f"參考  其中主執行緒 {main:.1f}%")
hitches = [r[2] for r in results if r[2] is not None]
if hitches:
    print(f"參考  錄音中主執行緒最長的卡頓 {max(hitches):.0f} ms（預算 ui.mainThreadHitch；隱藏執行時不準）")
sys.exit(0 if ok else 1)
PY
