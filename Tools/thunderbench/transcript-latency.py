#!/usr/bin/env python3
"""分析英文逐字稿的延遲與正確率。（M0b 探索用）

用法：transcript-latency.py <輸出資料夾> <synth 產生的 clip.json> [--loops N] [--terms <terms.json> --name keynote] [--quiet]

translate 與 transcribe 的輸出都能用（見 streamlib.py）。
- 首字延遲：一句的第一個字出現的時間，減去這一句開始說的時間。
- 末字延遲：一句的最後一個字出現的時間，減去這一句說完的時間。
- 句號延遲：這一句後面的句號（. ? !）出現的時間，減去這一句說完的時間。靠標點切句要等的就是這個。
- 定稿延遲（只有純轉錄連線、而且有 commit 時）：這一句所在的那一段收到完成事件的時間，減去這一句說完的時間。
- 錯字率（WER）：正規化（小寫、去標點）後的 替換＋漏字＋多字，除以稿子的字數。數字寫法不同（thirty percent／30%）也會算進去。
"""
import json
import statistics
import sys

from streamlib import Run, describe, pct

args = sys.argv[1:]


def option(name, default=None):
    if name in args:
        index = args.index(name)
        value = args[index + 1]
        del args[index:index + 2]
        return value
    return default


loops = int(option("--loops", "0"))
terms_path, terms_name = option("--terms"), option("--name")
quiet = "--quiet" in args
if quiet:
    args.remove("--quiet")
run = Run(args[0], args[1], loops)

first_word, last_word, terminator, finalized = [], [], [], []
missing_terminator = 0
rows = []
for index, s in enumerate(run.sentences):
    hits = run.sentence_words.get(index)
    if not hits:
        continue
    first, last = run.words[min(hits)], run.words[max(hits)]
    first_word.append(first["t"] - s["start"])
    last_word.append(last["t"] - s["end"])
    found = run.terminator_time(max(hits))
    if found is None:
        missing_terminator += 1
    else:
        terminator.append(found - s["end"])
    done = run.completed.get(last["item"])
    if done and len(run.commits) > 1:
        finalized.append(done["rx"] - s["end"])
    rows.append((index, None if found is None else found - s["end"]))

print(f"{run.name}：{len(run.sentences)} 句（{run.loops} 輪）、稿子 {len(run.reference)} 個字、收到 {len(run.words)} 個字、{len(run.deltas)} 個事件")
describe("首字延遲", first_word)
describe("末字延遲", last_word)
describe("句號延遲", terminator)
if finalized:
    describe("定稿延遲", finalized)
print(f"  沒有句號的句子：{missing_terminator}／{len(rows)}　錯字率 {run.wer * 100:.1f}%（替換 {run.substitutions}、漏 {run.deletions}、多 {run.insertions}）")

if len(run.commits) > 1:
    # commit 送出到收到完成事件；依序配對（第 k 次 commit 對第 k 個 committed 的段）
    waits, turns = [], []
    for commit, (_, item) in zip(run.commits, run.committed_order):
        done = run.completed.get(item)
        if done:
            waits.append(done["rx"] - commit["rx_ms"] / 1000)
        turns.append(commit.get("turn_seconds", 0))
    reasons = {}
    for commit in run.commits:
        reasons[commit.get("reason", "?")] = reasons.get(commit.get("reason", "?"), 0) + 1
    print(f"  commit {len(run.commits)} 次（{reasons}）；每段長度 中位數 {statistics.median(turns):.1f} 秒、最長 {max(turns):.1f} 秒")
    describe("commit 到完成事件", waits)
    same = sum(1 for item, done in run.completed.items()
               if "".join(t for _, t, i in run.deltas if i == item).strip() == done["text"].strip())
    print(f"  完成事件的文字和增量相同：{same}／{len(run.completed)} 段")

if run.loops > 1:
    per_loop = len(run.clip["sentences"])
    for loop in range(run.loops):
        values = [r[1] for r in rows if loop * per_loop <= r[0] < (loop + 1) * per_loop and r[1] is not None]
        if values:
            print(f"    第 {loop + 1:>2} 輪 句號延遲 中位數 {statistics.median(values):.2f}　P95 {pct(values, 0.95):.2f}　（{len(values)} 句）")
if not quiet and run.differences:
    print("  和稿子不同的地方（稿子 → 收到）：")
    for expected, got in run.differences[:25]:
        print(f"    {expected or '∅'} → {got or '∅'}")
if terms_path and terms_name:
    keep = json.load(open(terms_path, encoding="utf-8")).get(terms_name, {}).get("keep", [])
    if keep:
        found = [term for term in keep if term.lower() in run.stream.lower()]
        print(f"  專有名詞照原樣出現：{len(found)}／{len(keep)}　缺：{[t for t in keep if t not in found]}")

json.dump({"first_word": first_word, "last_word": last_word, "terminator": terminator, "finalized": finalized, "wer": run.wer,
           "missing_terminator": missing_terminator, "sentences": len(rows), "differences": run.differences},
          open(f"{run.run_dir}/transcript-latency.json", "w"), ensure_ascii=False)
