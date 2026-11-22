#!/usr/bin/env python3
"""驗證整句模式的正式引擎（thunderbench live --sentences --events）：句子、整句定稿的延遲、畫面上的改寫。

用法：sentence-validate.py <events.jsonl>

畫面照 App 的規則重建（暫定譯文關閉）：一句的整句定稿到之前，這一句各段的定稿接起來當灰字；
整句定稿到了換成白字。「改寫」= 畫面上已經有的中文被換掉（灰字被整句定稿取代，而且內容不同）。
"""
import json
import statistics
import sys

segments = {}
finals = []        # 整句定稿：(t, sentence, first, last, text)
fragments = {}     # 段 → [(t, text)]
for line in open(sys.argv[1], encoding="utf-8"):
    e = json.loads(line)
    n = e.get("segment")
    kind, t = e["kind"], e["t"]
    if kind in ("source_delta", "source_end") and n is not None:
        s = segments.setdefault(n, {"start": t, "end": None, "sentence": None, "text": ""})
        if kind == "source_end":
            if s["end"] is None:
                s["end"] = t
            s["sentence"] = e.get("sentence")
            s["text"] = e["text"]
    elif kind == "translation":
        if e.get("first") is not None:
            finals.append((t, e.get("sentence"), e["first"], n, e["text"]))
        else:
            fragments.setdefault(n, []).append((t, e["text"]))

def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else float("nan")

latest = {}
for final in finals:
    latest[final[1]] = final  # 重翻時以最後一次為準（延遲用第一次）
first_final = {}
for final in finals:
    first_final.setdefault(final[1], final)

delays, first_zh, rewritten, split, fallback = [], [], 0, 0, 0
for number, (t, _, first, last, text) in sorted(first_final.items()):
    members = [n for n in range(first, last + 1) if n in segments]
    if not members:
        continue
    start = segments[members[0]]["start"]
    end = segments[members[-1]]["end"]
    delays.append(t - end)
    gray = [(ft, fx) for n in members for ft, fx in fragments.get(n, []) if ft < t]
    shown = [ft for ft, _ in gray]
    first_zh.append(min(shown + [t]) - start)
    if len(members) > 1:
        split += 1
    gray_text = "".join(fx for _, fx in sorted(gray))
    if gray_text and gray_text != text:
        rewritten += 1
    own = "".join(fx for n in members for _, fx in fragments.get(n, [])[-1:])
    if own and own == text:
        fallback += 1

total = len(first_final)
print(f"段 {len(segments)}、整句定稿 {total} 句（重翻 {len(finals) - total} 次），切成 2 段以上的句 {split}（{split / max(1, total) * 100:.0f}%）")
print(f"整句定稿：一句說完（最後一段的英文確定）之後 中位數 {statistics.median(delays):.2f} 秒、P95 {pct(delays, 0.95):.2f} 秒")
print(f"第一個中文字：這一句第一個英文字出現之後 中位數 {statistics.median(first_zh):.2f} 秒、P95 {pct(first_zh, 0.95):.2f} 秒")
print(f"畫面上的中文被改寫過的句子 {rewritten}（{rewritten / max(1, total) * 100:.0f}%）；看起來是備用譯文（各段定稿接起來）的句子 {fallback}")
ends = sum(1 for _, _, _, _, x in finals if x.rstrip().endswith("。"))
print(f"整句定稿以「。」結尾的 {ends}／{len(finals)}（畫面上會拿掉）")
print("\n前 6 句被切開的句子：")
shown_count = 0
for number, (t, _, first, last, text) in sorted(first_final.items()):
    if last > first and shown_count < 6:
        en = " ｜ ".join(segments[n]["text"] for n in range(first, last + 1) if n in segments)
        print(f"  EN {en}\n  ZH {latest[number][4]}\n")
        shown_count += 1
