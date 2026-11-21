#!/usr/bin/env python3
"""用音量偵測停頓，算出「何時 commit」的位置。（探索用，不需要 API）

用法：vad-plan.py <音檔.wav> --out <前綴> [--silence-ms 300] [--min-turn-ms 0] [--long-silence-ms 700]
                  [--fixed <門檻>] [--mix 0.25] [--window 20]

輸出：
- <前綴>.commits.txt：每行一個音訊位置（毫秒），給 thunderbench transcribe --commit plan:<檔案>
- <前綴>.vad.json：每一段的語音起訖、commit 位置與統計

做法和即時執行時一樣，只看「過去」的音訊：
- 每 20 ms 算一次音量（RMS）。
- 門檻：預設是自適應的。取最近 window 秒的音量，低的一端（第 10 百分位）當底噪、高的一端（第 90 百分位）當語音，
  門檻放在兩者之間（對數刻度）靠近底噪 mix 的位置。現場收音的底噪很高，固定門檻會完全偵測不到停頓。
  用 --fixed 可以改用固定門檻。
- 說話之後出現連續 silence-ms 的靜音就 commit。
- --min-turn-ms：這一段還不到這麼長時，要等到更長的停頓（--long-silence-ms）才 commit，避免切出很短的碎片。
"""
import array
import bisect
import json
import math
import sys
import wave

args = sys.argv[1:]


def option(name, default=None):
    if name in args:
        index = args.index(name)
        value = args[index + 1]
        del args[index:index + 2]
        return value
    return default


out_prefix = option("--out")
silence_ms = int(option("--silence-ms", "300"))
min_turn_ms = int(option("--min-turn-ms", "0"))
long_silence_ms = int(option("--long-silence-ms", "700"))
fixed = option("--fixed")
mix = float(option("--mix", "0.25"))
window_seconds = float(option("--window", "20"))
if not args or not out_prefix:
    sys.exit(__doc__)

FRAME_MS = 20
source = wave.open(args[0], "rb")
rate = source.getframerate()
if source.getnchannels() != 1 or source.getsampwidth() != 2:
    sys.exit("音檔必須是 16-bit PCM 單聲道")
samples = array.array("h")
samples.frombytes(source.readframes(source.getnframes()))
frame = rate * FRAME_MS // 1000
levels = []
for index in range(0, len(samples) - frame + 1, frame):
    chunk = samples[index:index + frame]
    levels.append(math.sqrt(sum(x * x for x in chunk) / frame))

# --- 每一格的門檻（只看過去）---
thresholds = []
if fixed is not None:
    thresholds = [float(fixed)] * len(levels)
else:
    size = int(window_seconds * 1000 / FRAME_MS)
    recent, ordered = [], []
    for level in levels:
        recent.append(level)
        bisect.insort(ordered, level)
        if len(recent) > size:
            oldest = recent.pop(0)
            del ordered[bisect.bisect_left(ordered, oldest)]
        low = max(ordered[int(0.10 * (len(ordered) - 1))], 1.0)
        high = max(ordered[int(0.90 * (len(ordered) - 1))], low * 1.5)
        thresholds.append(max(60.0, math.exp(math.log(low) + mix * (math.log(high) - math.log(low)))))

# --- 找 commit 的位置 ---
commits, turns = [], []
speech_frames = 0          # 這一段裡累計的語音格數
first_speech = None        # 這一段第一格語音的位置（毫秒）
last_speech_end = None     # 最近一格語音結束的位置（毫秒）
silence_run = 0
turn_start = 0
for index, level in enumerate(levels):
    position = (index + 1) * FRAME_MS
    if level > thresholds[index]:
        speech_frames += 1
        if first_speech is None and speech_frames >= 2:
            first_speech = position - 2 * FRAME_MS
        last_speech_end = position
        silence_run = 0
    else:
        silence_run += FRAME_MS
    if first_speech is None:
        continue
    need = silence_ms
    if min_turn_ms and position - turn_start < min_turn_ms:
        need = long_silence_ms
    if silence_run >= need:
        commits.append(position)
        turns.append({"start_ms": turn_start, "commit_ms": position, "speech_start_ms": first_speech, "speech_end_ms": last_speech_end})
        turn_start = position
        speech_frames, first_speech, silence_run = 0, None, 0
if first_speech is not None:
    end = len(levels) * FRAME_MS
    turns.append({"start_ms": turn_start, "commit_ms": end, "speech_start_ms": first_speech, "speech_end_ms": last_speech_end})

lengths = sorted((t["commit_ms"] - t["start_ms"]) / 1000 for t in turns)


def quantile(q):
    return lengths[int(q * (len(lengths) - 1))] if lengths else 0.0


minutes = len(levels) * FRAME_MS / 60000
ordered_thresholds = sorted(thresholds)
stats = {
    "minutes": round(minutes, 2), "turns": len(turns), "commits_per_minute": round(len(commits) / minutes, 1),
    "turn_seconds_median": round(quantile(0.5), 1), "turn_seconds_p90": round(quantile(0.9), 1),
    "turn_seconds_max": round(lengths[-1], 1) if lengths else 0,
    "turns_shorter_than_2s_percent": round(100 * sum(1 for x in lengths if x < 2) / max(1, len(lengths))),
    "threshold_median": round(ordered_thresholds[len(ordered_thresholds) // 2]),
}
open(out_prefix + ".commits.txt", "w").write("".join(f"{c}\n" for c in commits))
json.dump({"params": {"silence_ms": silence_ms, "min_turn_ms": min_turn_ms, "long_silence_ms": long_silence_ms,
                      "fixed": fixed, "mix": mix, "window_seconds": window_seconds},
           "stats": stats, "turns": turns}, open(out_prefix + ".vad.json", "w"), indent=1)
print(f"{out_prefix}: {stats}")
