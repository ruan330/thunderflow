#!/usr/bin/env python3
"""實驗：用同一份即時引擎的事件（`thunderbench live --events`），比較三種中文，並重建畫面上每一刻顯示的字。

用法：OPENAI_API_KEY=... sentence-retranslate.py <events.jsonl> <輸出資料夾> [--model gpt-6-luna] [--effort none]

三種中文（英文都一樣，是即時引擎聽到的英文；差別只在怎麼翻）：
- 現在：即時引擎當場逐段翻的定稿（不重新呼叫）。
- A：一句說完就整句重翻。依序呼叫，每句附前 3 句的英文與 A 自己的中文（模擬當場只看得到前文）。
- 整場：整場一次翻（DeepSRT 的做法），結構化輸出，每句一個編號。當作上限。

畫面上的改動（「字一直變」），四種顯示方式：
- D0 現在：每段一行，暫定譯文 → 段的定稿（白字）。
- D1 A：段照現在的方式先出（灰字），整句譯文回來後取代那幾段（白字）。
- D2 A＋不顯示暫定譯文：只先出段的定稿（灰字），再換成整句譯文。
- D3 A＋只顯示穩定的開頭：暫定譯文只顯示連續兩版相同的開頭（M0b 6.5 節的做法），再換成整句譯文。
"""
import html
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

events_path, out_dir = sys.argv[1], sys.argv[2]
argv = sys.argv[3:]
model = argv[argv.index("--model") + 1] if "--model" in argv else "gpt-6-luna"
effort = argv[argv.index("--effort") + 1] if "--effort" in argv else "none"
key = os.environ["OPENAI_API_KEY"].strip()
os.makedirs(out_dir, exist_ok=True)

# ---------------------------------------------------------------- 讀事件

segs = {}
for line in open(events_path, encoding="utf-8"):
    e = json.loads(line)
    n = e.get("segment")
    if n is None:
        continue
    s = segs.setdefault(n, {"start": None, "end": None, "en": "", "prov": [], "final": []})
    kind, t = e["kind"], e["t"]
    if kind == "source_delta":
        if s["start"] is None:
            s["start"] = t
    elif kind == "source_end":
        if s["end"] is None:
            s["end"] = t
        s["en"] = e["text"].strip()
    elif kind == "provisional":
        s["prov"].append((t, e["text"]))
    elif kind == "translation":
        s["final"].append((t, e["text"]))

order = sorted(n for n, s in segs.items() if s["en"])
for n in order:
    if segs[n]["start"] is None:
        segs[n]["start"] = segs[n]["end"]

# 依句號把段合成句；沒有句號時，一句最多 60 個字
END = re.compile(r"[.?!…][\"'”’)\]]*$")
sentences, current = [], []
for n in order:
    current.append(n)
    if END.search(segs[n]["en"]) or sum(len(segs[m]["en"].split()) for m in current) >= 60:
        sentences.append(current)
        current = []
if current:
    sentences.append(current)
sentence_en = [" ".join(segs[n]["en"] for n in sent) for sent in sentences]
print(f"段 {len(order)}、句 {len(sentences)}、切成 2 段以上的句 {sum(len(s) > 1 for s in sentences)}", flush=True)

# ---------------------------------------------------------------- 文字模型

usage_total = {"input": 0, "output": 0}


def call(instructions, text, max_tokens=400, schema=None):
    body = {"model": model, "instructions": instructions, "input": text, "stream": True,
            "max_output_tokens": max_tokens, "reasoning": {"effort": effort}}
    if schema:
        body["text"] = {"format": {"type": "json_schema", "name": "translations", "schema": schema, "strict": True}}
    data = json.dumps(body).encode()
    for attempt in range(3):
        request = urllib.request.Request("https://api.openai.com/v1/responses", data=data,
                                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        started, first, out = time.monotonic(), None, []
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                for raw in response:
                    line = raw.decode("utf-8").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    event = json.loads(payload)
                    kind = event.get("type")
                    if kind == "response.output_text.delta":
                        if first is None:
                            first = time.monotonic() - started
                        out.append(event.get("delta", ""))
                    elif kind == "response.completed":
                        usage = event.get("response", {}).get("usage") or {}
                        usage_total["input"] += usage.get("input_tokens", 0)
                        usage_total["output"] += usage.get("output_tokens", 0)
                    elif kind in ("error", "response.failed", "response.incomplete"):
                        raise RuntimeError(payload[:300])
            return "".join(out).strip(), first, time.monotonic() - started
        except (urllib.error.URLError, RuntimeError, TimeoutError) as error:
            if attempt == 2:
                raise
            print(f"  重試：{str(error)[:120]}", flush=True)
            time.sleep(1 + attempt)


STYLE = (
    "使用台灣的用語與技術詞彙（例如：推論、伺服器、資料、軟體、預設、端點、可用區域、無伺服器、記憶體、權杖或 token）。\n"
    "產品名稱與專有名詞保留英文原文，不要翻譯也不要拆開（例如 Amazon Bedrock、AgentCore、Graviton5、microVM、S3 Vectors、CloudWatch）。\n"
    "數字用阿拉伯數字。語氣自然、精簡，像字幕。"
)
SPOKEN = ("這是現場的口語：去掉 uh、um、you know、I mean，以及當口頭禪用的 right、like、so，"
          "還有重複的字和說到一半改口的部分，只留下講者要表達的意思。")

A_INSTRUCTIONS = "\n".join([
    "你是演講、課程與會議的即時字幕譯者。把使用者給的「這一句」英文翻成台灣繁體中文，供現場觀眾閱讀。",
    "規則：",
    "1. 譯成通順、自然的中文句子：依中文的語序重新組織，不要照英文的順序逐字翻。",
    "2. " + SPOKEN,
    "3. 「前文」是剛才的英文和已經顯示給觀眾的中文：用語與稱呼要和前文的中文一致，接得上前文，但不要重複前文已經翻過的內容。",
    "4. " + STYLE.split("\n")[0],
    "5. " + STYLE.split("\n")[1],
    "6. " + STYLE.split("\n")[2],
    "7. 只輸出這一句的譯文，不要加任何說明。",
])

WHOLE_INSTRUCTIONS = "\n".join([
    "你是演講逐字稿的譯者。使用者給的是一場演講的英文逐字稿，每一行是一句，開頭是編號與一個 tab。把每一句翻成台灣繁體中文。",
    "規則：",
    "1. 每個編號都要有一句譯文，編號不能增減。",
    "2. 譯成通順、自然的中文：依中文的語序重新組織，可以參考前後句讓整段讀起來連貫；但每句的譯文只放這一句的內容，不要把別句的內容移過來。",
    "3. " + SPOKEN,
    "4. 全場的用語與稱呼要一致。",
    "5. " + STYLE.split("\n")[0],
    "6. " + STYLE.split("\n")[1],
    "7. " + STYLE.split("\n")[2],
])

WHOLE_SCHEMA = {
    "type": "object",
    "properties": {"items": {"type": "array", "items": {
        "type": "object",
        "properties": {"id": {"type": "integer"}, "zh": {"type": "string"}},
        "required": ["id", "zh"], "additionalProperties": False}}},
    "required": ["items"], "additionalProperties": False,
}

cache_path = os.path.join(out_dir, "cache.json")
cache = json.load(open(cache_path, encoding="utf-8")) if os.path.exists(cache_path) else None
if cache and cache["sentence_en"] != sentence_en:
    cache = None

# A：依序整句重翻
a_zh, a_latency, a_first = [], [], []
for i, en in enumerate([] if cache else sentence_en):
    context = [f"英：{sentence_en[j]}\n中：{a_zh[j]}" for j in range(max(0, i - 3), i)]
    parts = (["前文（只供參考，不要翻譯）：\n" + "\n".join(context)] if context else []) + ["這一句：\n" + en]
    zh, first, total = call(A_INSTRUCTIONS, "\n\n".join(parts))
    a_zh.append(zh)
    a_latency.append(total)
    a_first.append(first if first is not None else total)
    if i % 10 == 0:
        print(f"  A：{i + 1}/{len(sentence_en)}，{total:.2f} 秒", flush=True)

# 整場一次翻（缺的編號再補一次）
if cache:
    a_zh, a_latency, a_first, whole_zh, whole_seconds = (cache[k] for k in ("a_zh", "a_latency", "a_first", "whole_zh", "whole_seconds"))
    usage_total.update(cache["usage"])
    print("  用存下來的 API 結果", flush=True)
listing = "\n".join(f"{i + 1}\t{en}" for i, en in enumerate(sentence_en))
if not cache:
    text, _, whole_seconds = call(WHOLE_INSTRUCTIONS, listing, max_tokens=20_000, schema=WHOLE_SCHEMA)
    whole = {item["id"]: item["zh"] for item in json.loads(text)["items"]}
missing = [] if cache else [i + 1 for i in range(len(sentence_en)) if not whole.get(i + 1)]
if missing:
    print(f"  整場：缺 {len(missing)} 句，補翻", flush=True)
    retry = "\n".join(f"{i}\t{sentence_en[i - 1]}" for i in missing)
    text, _, _ = call(WHOLE_INSTRUCTIONS, retry, max_tokens=8_000, schema=WHOLE_SCHEMA)
    whole.update({item["id"]: item["zh"] for item in json.loads(text)["items"]})
if not cache:
    whole_zh = [whole.get(i + 1, "") for i in range(len(sentence_en))]
    json.dump({"sentence_en": sentence_en, "a_zh": a_zh, "a_latency": a_latency, "a_first": a_first,
               "whole_zh": whole_zh, "whole_seconds": whole_seconds, "usage": usage_total},
              open(cache_path, "w", encoding="utf-8"), ensure_ascii=False)
print(f"  整場：{whole_seconds:.1f} 秒，缺 {sum(not z for z in whole_zh)} 句", flush=True)

# ---------------------------------------------------------------- 畫面上的改動


def lcp(a, b):
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def provisional_versions(prov):
    """把暫定譯文的事件合成「一版一版」：第一版是邊收邊送的（字一直往後接、間隔很短），算同一版。"""
    versions = []
    for t, text in prov:
        if versions and text.startswith(versions[-1][1]) and t - versions[-1][0] < 0.5:
            versions[-1] = (t, text)
        else:
            versions.append((t, text))
    return versions


def segment_timeline(n, policy, include_final=True):
    """這一段在畫面上依序顯示的字：[(時間, 文字, 是否白字)]。include_final 為 False 時不顯示這一段的定稿。"""
    s = segs[n]
    final_t = s["final"][0][0] if s["final"] else float("inf")
    prov = [(t, x) for t, x in s["prov"] if t < final_t]
    shown = []
    if policy == "as_is":
        shown = [(t, x, False) for t, x in prov]
    elif policy == "stable":
        versions = provisional_versions(prov)
        shown = [(versions[k][0], versions[k - 1][1][:lcp(versions[k - 1][1], versions[k][1])], False)
                 for k in range(1, len(versions))]
    return shown + ([(t, x, True) for t, x in s["final"]] if include_final else [])


def churn(sequence):
    """顯示的字依序是 sequence（從空白開始）：回傳（新出現的字數, 被改掉的字數, 改版次數, 改掉已顯示的字的次數）。"""
    added = removed = updates = rewrites = 0
    previous = ""
    for text in sequence:
        if text == previous:
            continue
        keep = lcp(previous, text)
        added += len(text) - keep
        removed += len(previous) - keep
        updates += 1
        rewrites += len(previous) > keep
        previous = text
    return added, removed, updates, rewrites


def simulate(policy, sentence_level):
    totals = {"added": 0, "removed": 0, "updates": 0, "rewrites": 0, "white_added": 0, "white_removed": 0}
    first_delays, white_delays, rewrites_per_sentence = [], [], []
    for i, sent in enumerate(sentences):
        start, end = segs[sent[0]]["start"], segs[sent[-1]]["end"]
        arrive = end + a_latency[i] if sentence_level else float("inf")
        sentence_rewrites = 0
        firsts = []
        last_shown = []
        for k, n in enumerate(sent):
            # 整句重翻時，最後一段不另外送定稿：句子在這一段結束，整句譯文就是它的定稿
            include_final = not (sentence_level and k == len(sent) - 1)
            line = [(t, x, white) for t, x, white in segment_timeline(n, policy, include_final) if t < arrive]
            if sentence_level:
                line = [(t, x, False) for t, x, _ in line]   # 整句譯文回來之前都是灰字
            added, removed, updates, rewrites = churn([x for _, x, _ in line])
            totals["added"] += added
            totals["removed"] += removed
            totals["updates"] += updates
            totals["rewrites"] += rewrites
            sentence_rewrites += rewrites
            whites = [x for _, x, white in line if white]
            if whites:
                w_added, w_removed, _, _ = churn(whites)
                totals["white_added"] += w_added
                totals["white_removed"] += w_removed
            firsts += [t for t, x, _ in line if x]
            last_shown.append(line[-1][1] if line else "")
        if sentence_level:
            before = "".join(last_shown)
            keep = lcp(before, a_zh[i])
            totals["added"] += len(a_zh[i]) - keep
            totals["removed"] += len(before) - keep
            totals["updates"] += 1
            totals["rewrites"] += len(before) > keep
            sentence_rewrites += len(before) > keep
            totals["white_added"] += len(a_zh[i])
            firsts.append(arrive)
            white_delays.append(arrive - end)
        else:
            finals = [segs[n]["final"][0][0] for n in sent if segs[n]["final"]]
            if len(finals) == len(sent):
                white_delays.append(max(finals) - end)
        if firsts:
            first_delays.append(min(firsts) - start)
        rewrites_per_sentence.append(sentence_rewrites)
    return {
        "displayed_changed": totals["removed"] / max(1, totals["added"]),
        "rewrite_updates": totals["rewrites"] / max(1, totals["updates"]),
        "rewrites_per_sentence": statistics.mean(rewrites_per_sentence),
        "sentences_rewritten": sum(1 for r in rewrites_per_sentence if r) / len(rewrites_per_sentence),
        "white_changed": totals["white_removed"] / max(1, totals["white_added"]),
        "first_median": statistics.median(first_delays),
        "white_median": statistics.median(white_delays),
        "white_p95": sorted(white_delays)[int(len(white_delays) * 0.95)],
    }


variants = [
    ("D0 現在", "as_is", False),
    ("D0b 現在＋關掉暫定譯文", "none", False),
    ("D1 A（段先出，整句譯文取代）", "as_is", True),
    ("D2 A＋不顯示暫定譯文", "none", True),
    ("D3 A＋只顯示穩定的開頭", "stable", True),
]
metrics = {name: simulate(policy, level) for name, policy, level in variants}

result = {
    "model": model, "effort": effort, "segments": len(order), "sentences": len(sentences),
    "split_sentences": sum(len(s) > 1 for s in sentences),
    "a_latency_median": statistics.median(a_latency), "a_latency_p95": sorted(a_latency)[int(len(a_latency) * 0.95)],
    "whole_seconds": whole_seconds, "usage": usage_total, "metrics": metrics,
    "rows": [{"segments": sent, "en": [segs[n]["en"] for n in sent],
              "now": [segs[n]["final"][-1][1] if segs[n]["final"] else "（沒有定稿）" for n in sent],
              "a": a_zh[i], "whole": whole_zh[i]} for i, sent in enumerate(sentences)],
}
json.dump(result, open(os.path.join(out_dir, "result.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
for name, m in metrics.items():
    print(f"{name}：顯示過的字被改掉 {m['displayed_changed'] * 100:.0f}%、改掉已顯示字的更新 {m['rewrite_updates'] * 100:.0f}%、"
          f"每句 {m['rewrites_per_sentence']:.1f} 次（{m['sentences_rewritten'] * 100:.0f}% 的句子有改寫）、白字被改 {m['white_changed'] * 100:.0f}%、"
          f"第一個中文字 {m['first_median']:.2f} 秒、白字到齊 {m['white_median']:.2f}／{m['white_p95']:.2f} 秒")
print(f"A 的整句翻譯：中位數 {result['a_latency_median']:.2f} 秒、P95 {result['a_latency_p95']:.2f} 秒；token 輸入 {usage_total['input']}、輸出 {usage_total['output']}")
