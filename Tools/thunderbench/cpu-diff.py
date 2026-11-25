#!/usr/bin/env python3
"""比較兩次 `ps -A -o pid=,time=,comm=` 的快照：這段時間裡每個程序用掉多少 CPU 時間。（探索用）

用法：cpu-diff.py <之前.txt> <之後.txt> <經過的秒數> [--top 12]

用來量本機語音辨識的 CPU：辨識模型可能在系統的其他程序裡跑，只看自己的程序會少算。
百分比以一個核心為 100%（和「活動監視器」相同）。期間新開的程序從 0 算起；期間結束的程序看不到。
"""
import os
import sys


def seconds(text):
    """ps 的 time 欄位（[[天-]時:]分:秒.百分秒）→ 秒。"""
    days = 0
    if "-" in text:
        day, text = text.split("-", 1)
        days = int(day)
    total = 0.0
    for part in text.split(":"):
        total = total * 60 + float(part)
    return days * 86400 + total


def snapshot(path):
    result = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        fields = line.split(None, 2)
        if len(fields) == 3:
            result[fields[0]] = (seconds(fields[1]), os.path.basename(fields[2].strip()))
    return result


if len(sys.argv) < 4:
    sys.exit(__doc__)
before, after, elapsed = snapshot(sys.argv[1]), snapshot(sys.argv[2]), float(sys.argv[3])
top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 12
changes = []
for pid, (used, name) in after.items():
    delta = used - before.get(pid, (0.0, name))[0]
    if delta > 0:
        changes.append((delta, pid, name))
changes.sort(reverse=True)
print(f"經過 {elapsed:.0f} 秒；全部程序合計 {sum(c[0] for c in changes):.1f} 秒 CPU（{sum(c[0] for c in changes) / elapsed * 100:.1f}%）")
for delta, pid, name in changes[:top]:
    print(f"  {delta:7.2f} 秒  {delta / elapsed * 100:5.1f}%  {name}（{pid}）")
