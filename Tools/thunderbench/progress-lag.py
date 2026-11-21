#!/usr/bin/env python3
"""中文落後講者多少（不需要對齊句子）。（探索用）

用法：progress-lag.py <clip.json> <來源> [<來源> …]
來源可以是：
- translate 的輸出資料夾（用即時翻譯模型自己的中文，事件 session.output_transcript.delta）
- pipeline.py 的輸出資料夾（…/pipeline-<label>，用每一段的中文定稿）

算法：講者說到全文的 q% 的時間，和畫面上的中文顯示到全文的 q% 的時間，兩者的差。對 q＝5…95 取中位數與第 90 百分位。
講者的進度來自參考稿每個字的時間（沒有逐字時間就把每句的字平均攤在句子的起訖之間）。
只比較參考稿涵蓋的那一段時間。
"""
import json
import os
import statistics
import sys

clip = json.load(open(sys.argv[1], encoding="utf-8"))
if clip.get("words"):
    spoken_times = [w["end"] for w in clip["words"]]
else:
    spoken_times = []
    for s in clip["sentences"]:
        count = len(s["text"].split())
        spoken_times += [s["start"] + (s["end"] - s["start"]) * (k + 1) / count for k in range(count)]
spoken = [(t, (k + 1) / len(spoken_times)) for k, t in enumerate(spoken_times)]
last_spoken = spoken_times[-1]


def time_at(series, fraction):
    for t, f in series:
        if f >= fraction:
            return t
    return series[-1][0]


for source in sys.argv[2:]:
    shown_events = []  # (time, chars)
    if os.path.exists(f"{source}/pipeline.json"):
        data = json.load(open(f"{source}/pipeline.json", encoding="utf-8"))
        for request in data["requests"]:
            if request["kind"] == "final":
                shown_events.append((request["t"] + request["total"], len(request["zh"])))
        kind = "逐段翻譯的定稿"
    else:
        for line in open(f"{source}/events.jsonl", encoding="utf-8"):
            e = json.loads(line)
            if e.get("event", {}).get("type") == "session.output_transcript.delta" and "rx_ms" in e:
                shown_events.append((e["rx_ms"] / 1000, len(e["event"].get("delta", ""))))
        kind = "即時翻譯模型的中文"
    shown_events = [(t, n) for t, n in sorted(shown_events) if t <= last_spoken + 8]
    total = sum(n for _, n in shown_events)
    shown, count = [], 0
    for t, n in shown_events:
        count += n
        shown.append((t, count / total))
    lags = [time_at(shown, q / 100) - time_at(spoken, q / 100) for q in range(5, 96)]
    ordered = sorted(lags)
    print(f"{source.rstrip('/').split('/')[-2] + '/' + source.rstrip('/').split('/')[-1] if 'pipeline-' in source else source.rstrip('/').split('/')[-1]}［{kind}］："
          f"中文落後 中位數 {statistics.median(lags):.2f} 秒、第 90 百分位 {ordered[int(0.9 * (len(ordered) - 1))]:.2f} 秒、最大 {max(lags):.2f} 秒（共 {total} 個字）")
