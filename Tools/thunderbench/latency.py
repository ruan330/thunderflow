#!/usr/bin/env python3
"""分析一次 translate 實驗的延遲。（M0 探索用）

用法：latency.py <translate 的輸出資料夾> <synth 產生的 clip.json>

時間基準：rx_ms 是「從開始送音訊算起」收到事件的時間；以即時速度送音訊時，它等於當下已經播到的音訊位置。
- 英文延遲：某個字的字幕出現的時間，減去那個字在音檔裡的位置（以句子的起訖時間估計）。
- 首字延遲：一句英文開始說，到畫面上出現這一句的第一個中文字。
- 句末延遲：一句英文說完，到下一個中文句號出現（讀者拿到完整的句子）。
- 平均落後：不對齊句子，直接比較「英文說到全文的 q%」與「中文顯示到全文的 q%」的時間差。
"""
import json
import statistics
import sys

run_dir, clip_path = sys.argv[1], sys.argv[2]
events = [json.loads(line) for line in open(f"{run_dir}/events.jsonl", encoding="utf-8")]
clip = json.load(open(clip_path, encoding="utf-8"))
sentences = clip["sentences"]


def deltas(kind):
    return [(e["rx_ms"] / 1000, e["event"].get("elapsed_ms", 0) / 1000, e["event"].get("delta", ""))
            for e in events if e["event"].get("type") == kind and "rx_ms" in e]


source, target = deltas("session.input_transcript.delta"), deltas("session.output_transcript.delta")


def pct(values, q):
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def describe(name, values):
    if not values:
        print(f"  {name}: 沒有資料")
        return
    print(f"  {name}: 中位數 {statistics.median(values):.2f} 秒　P95 {pct(values, 0.95):.2f}　最小 {min(values):.2f}　最大 {max(values):.2f}　（{len(values)} 筆）")


# --- 英文：每句的第一個字與最後一個字 ---
en_first, en_last = [], []
for index, sentence in enumerate(sentences):
    window_end = sentences[index + 1]["start"] if index + 1 < len(sentences) else sentence["end"] + 3
    # elapsed 是模型時間（與音訊位置同一個時鐘）。用它把字幕歸到句子，容許 0.15 秒的起始誤差
    mine = [d for d in source if sentence["start"] + 0.15 <= d[1] < window_end + 0.15]
    if mine:
        en_first.append(mine[0][0] - sentence["start"])
        en_last.append(mine[-1][0] - sentence["end"])

# --- 中文：切成句子（。？！與半形的 ?!） ---
TERMINATORS = "。？！?!"
zh_sentences, current = [], None
for rx, elapsed, text in target:
    if current is None:
        current = {"start": rx, "text": ""}
    current["text"] += text
    current["end"] = rx
    if any(ch in TERMINATORS for ch in text):
        zh_sentences.append(current)
        current = None
if current:
    zh_sentences.append(current)

first_char, sentence_end = [], []
for index, sentence in enumerate(sentences):
    next_start = sentences[index + 1]["start"] if index + 1 < len(sentences) else sentence["end"] + 8
    # 首字：這一句開始之後，第一個「新開始的中文句子」
    starts = [z["start"] for z in zh_sentences if sentence["start"] + 0.1 <= z["start"] < next_start + 0.1]
    if starts:
        first_char.append(starts[0] - sentence["start"])
    # 句末：這一句說完之後，第一個中文句子的結尾
    ends = [z["end"] for z in zh_sentences if z["end"] >= sentence["end"] - 0.2]
    if ends:
        sentence_end.append(ends[0] - sentence["end"])

# --- 平均落後：內容進度的時間差 ---
total_words = sum(len(s["text"].split()) for s in sentences)
spoken, done = [], 0  # (time, fraction of words spoken)
for s in sentences:
    words = len(s["text"].split())
    for k in range(1, words + 1):
        spoken.append((s["start"] + (s["end"] - s["start"]) * k / words, (done + k) / total_words))
    done += words
total_chars = sum(len(t) for _, _, t in target)
shown, count = [], 0
for rx, _, text in target:
    count += len(text)
    shown.append((rx, count / total_chars))


def time_at(series, fraction):
    for t, f in series:
        if f >= fraction:
            return t
    return series[-1][0]


lagging = [time_at(shown, q / 100) - time_at(spoken, q / 100) for q in range(5, 96)]

print(f"音檔 {clip['duration']} 秒、{len(sentences)} 句；英文字幕事件 {len(source)} 個、中文字幕事件 {len(target)} 個、中文句子 {len(zh_sentences)} 句")
if source:
    print(f"第一個英文字：{source[0][0]:.2f} 秒；", end="")
if target:
    print(f"第一個中文字：{target[0][0]:.2f} 秒（第一句從 {sentences[0]['start']} 秒開始說）")
describe("英文 每句第一個字的延遲", en_first)
describe("英文 每句最後一個字的延遲", en_last)
describe("中文 首字延遲", first_char)
describe("中文 句末延遲", sentence_end)
describe("中文 平均落後（內容進度）", lagging)
gaps = [b[0] - a[0] for a, b in zip(target, target[1:])]
if gaps:
    print(f"  中文字幕事件的間隔：中位數 {statistics.median(gaps) * 1000:.0f} ms，最長 {max(gaps):.2f} 秒；每個事件平均 {total_chars / len(target):.1f} 個字")
skew = [rx - el for rx, el, _ in source]
if skew:
    print(f"  英文字幕：收到時間 − elapsed_ms 的中位數 {statistics.median(skew) * 1000:.0f} ms（elapsed_ms 可以當成字幕在音訊時間軸上的位置）")
json.dump({
    "en_first_word": en_first, "en_last_word": en_last, "zh_first_char": first_char, "zh_sentence_end": sentence_end,
    "zh_average_lagging": lagging,
}, open(f"{run_dir}/latency.json", "w"))
