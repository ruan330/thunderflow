#!/usr/bin/env python3
"""M0b：把錄下來的英文逐字稿時間軸接上「切句 → 文字模型翻譯」，算出端到端的延遲。（探索用）

用法：pipeline.py <輸出資料夾> <clip.json> [--trigger period|turn] [--partials] [--partial-words 3] [--partial-interval 1.0]
                  [--model gpt-6-luna] [--effort none] [--loops N] [--label 名稱] [--workers 6] [--show]

時間是「虛擬」的：英文每個字到達的時間來自錄下來的事件；翻譯是真的呼叫 API，量它花多久，再把這段時間接在
觸發時間後面。何時觸發只由英文的時間軸決定，所以翻譯可以平行呼叫，結果和真正即時執行相同（忽略連線之間互相影響）。

切段（--trigger）：
- period：看到句號（. ? !），而且後面接的是空白或 0.2 秒內沒有別的字，就把這一句送去翻譯。兩種連線都能用。
- turn：純轉錄連線專用。除了句號，一段音訊 commit 之後收到完成事件，也把還沒翻的文字送去翻譯。

暫定譯文（--partials）：一句還沒說完時，每多 N 個字、而且距離上次至少 T 秒，就把目前的半句送去翻譯，
畫面上先顯示這個暫定的譯文，整句完成後再換成定稿。

從環境變數 OPENAI_API_KEY 讀金鑰（不會印出）。
"""
import concurrent.futures
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

from streamlib import Run, describe

args = sys.argv[1:]


def option(name, default=None):
    if name in args:
        index = args.index(name)
        value = args[index + 1]
        del args[index:index + 2]
        return value
    return default


def flag(name):
    if name in args:
        args.remove(name)
        return True
    return False


trigger_mode = option("--trigger", "period")
partial_words = int(option("--partial-words", "3"))
partial_interval = float(option("--partial-interval", "1.0"))
model = option("--model", "gpt-6-luna")
effort = option("--effort", "none")
loops = int(option("--loops", "0"))
label = option("--label")
workers = int(option("--workers", "6"))
with_partials = flag("--partials")
show = flag("--show")
dry_run = flag("--dry-run")
run = Run(args[0], args[1], loops)
label = label or f"{trigger_mode}{'-partials' if with_partials else ''}"
key = "" if dry_run else os.environ["OPENAI_API_KEY"].strip()

ABBREVIATIONS = {"mr", "mrs", "ms", "dr", "prof", "vs", "etc", "eg", "ie", "st", "no", "inc", "ltd", "us"}
CONFIRM_SECONDS = 0.2

# ---------------------------------------------------------------- 切段

chars, stream = run.chars, run.stream


def boundary_after(position):
    """position 是句號的位置。是句子的結尾就回傳確認的時間，否則回傳 None。"""
    rx = chars[position][1]
    if stream[position] in "。？！":
        return rx  # 中文的句號不會和小數點、縮寫混淆，直接算句子結束
    # 縮寫（Dr. e.g.）不算
    before = re.findall(r"[A-Za-z]+", stream[max(0, position - 6):position])
    if before and before[-1].lower() in ABBREVIATIONS and stream[position] == ".":
        return None
    follow = position + 1
    while follow < len(chars) and chars[follow][0] in "\"'”’)":
        follow += 1
    if follow >= len(chars):
        return rx + CONFIRM_SECONDS
    next_char, next_rx, _ = chars[follow]
    if next_rx - rx > CONFIRM_SECONDS:
        return rx + CONFIRM_SECONDS  # 等了 0.2 秒沒有別的字，當成句子結束
    if next_char.isspace():
        return next_rx  # 後面接空白（下一個字）才確認；1.5 這種小數點後面直接接數字
    return None


boundaries = []  # (字元位置（含）, 確認時間, 原因)
for position, (ch, rx, item) in enumerate(chars):
    if ch in ".?!。？！":
        confirmed = boundary_after(position)
        if confirmed is not None:
            boundaries.append((position, confirmed, "period"))
if trigger_mode == "turn":
    # 每一段完成時，這一段最後一個字元也是邊界
    last_position = {}
    for position, (_, _, item) in enumerate(chars):
        last_position[item] = position
    for item, done in run.completed.items():
        if item in last_position:
            boundaries.append((last_position[item], done["rx"], "turn"))
# 同一個位置取最早確認的；位置在前的邊界不能比後面的晚（後面確認了，前面也就確定了）
earliest = {}
for position, confirmed, reason in boundaries:
    if position not in earliest or confirmed < earliest[position][0]:
        earliest[position] = (confirmed, reason)
ordered = sorted(earliest.items())
if not ordered or ordered[-1][0] < len(chars) - 1:
    tail_time = chars[-1][1] + CONFIRM_SECONDS
    ordered.append((len(chars) - 1, (tail_time, "end")))
segments = []  # {"start": 字元起點, "end": 字元終點（不含）, "text", "t": 觸發時間, "reason"}
cursor = 0
for position, (confirmed, reason) in ordered:
    text = stream[cursor:position + 1].strip()
    if not re.search(r"\w", text):
        continue
    if reason == "turn" and segments and segments[-1]["end"] > position:
        continue
    segments.append({"start": cursor, "end": position + 1, "text": text, "t": confirmed, "reason": reason})
    cursor = position + 1

# 每個字屬於哪一段
for word_index, word in enumerate(run.words):
    for segment_index, segment in enumerate(segments):
        if segment["start"] <= word["start"] < segment["end"]:
            word["segment"] = segment_index
            break

# ---------------------------------------------------------------- 要送出的翻譯請求

requests = []  # {"segment", "kind": final|partial, "t": 觸發時間, "text", "context"}
for segment_index, segment in enumerate(segments):
    context = [s["text"] for s in segments[max(0, segment_index - 2):segment_index]]
    if with_partials:
        mine = [w for w in run.words if w.get("segment") == segment_index]
        last_trigger, last_count = None, 0
        for count, word in enumerate(mine, start=1):
            if word["t"] >= segment["t"]:
                break
            if count == len(mine):
                break  # 最後一個字到了之後等的是定稿
            if count - last_count >= partial_words and (last_trigger is None or word["t"] - last_trigger >= partial_interval):
                text = stream[segment["start"]:word["end"]].strip()
                requests.append({"segment": segment_index, "kind": "partial", "t": word["t"], "text": text, "context": context, "words": count})
                last_trigger, last_count = word["t"], count
    requests.append({"segment": segment_index, "kind": "final", "t": segment["t"], "text": segment["text"], "context": context})

RULES = (
    "規則：\n"
    "1. 使用台灣的用語與技術詞彙（例如：推論、伺服器、資料、軟體、預設、端點、可用區域、無伺服器、記憶體、權杖或 token）。\n"
    "2. 產品名稱與專有名詞保留英文原文，不要翻譯也不要拆開（例如 Amazon Bedrock、AgentCore、Graviton5、microVM、S3 Vectors、CloudWatch）。\n"
    "3. 數字用阿拉伯數字。語氣自然、精簡，像字幕。\n"
)
FINAL_INSTRUCTIONS = (
    "你是技術研討會的即時字幕譯者。把使用者給的「這一句」英文翻成台灣繁體中文，供現場觀眾閱讀。\n" + RULES +
    "4. 只輸出這一句的譯文，不要重複前文，不要加任何說明。"
)
PARTIAL_INSTRUCTIONS = (
    "你是技術研討會的即時字幕譯者。講者還沒說完這一句，使用者給的是「目前聽到的部分」。把它翻成台灣繁體中文，供現場觀眾先看。\n" + RULES +
    "4. 只翻譯已經聽到的內容，不要猜測或補完後面還沒說的部分，結尾不要加句號。\n"
    "5. 只輸出譯文，不要重複前文，不要加任何說明。"
)


def translate(request):
    parts = []
    if request["context"]:
        parts.append("前文（只供參考，不要翻譯）：\n" + "\n".join(request["context"]))
    parts.append(("這一句：\n" if request["kind"] == "final" else "目前聽到的部分：\n") + request["text"])
    body = {"model": model, "instructions": FINAL_INSTRUCTIONS if request["kind"] == "final" else PARTIAL_INSTRUCTIONS,
            "input": "\n\n".join(parts), "stream": True, "max_output_tokens": 400}
    if effort != "omit":
        body["reasoning"] = {"effort": effort}
    for attempt in range(3):
        http = urllib.request.Request(
            "https://api.openai.com/v1/responses", data=json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        start = time.monotonic()
        first, text, usage = None, "", {}
        try:
            with urllib.request.urlopen(http, timeout=60) as response:
                for raw in response:
                    line = raw.decode("utf-8").strip()
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        break
                    event = json.loads(payload)
                    if event.get("type") == "response.output_text.delta":
                        if first is None:
                            first = time.monotonic() - start
                        text += event.get("delta", "")
                    elif event.get("type") == "response.completed":
                        usage = event.get("response", {}).get("usage", {})
            total = time.monotonic() - start
            return {"zh": text.strip(), "first": first if first is not None else total, "total": total,
                    "in": usage.get("input_tokens", 0), "out": usage.get("output_tokens", 0)}
        except urllib.error.HTTPError as error:
            message = error.read().decode("utf-8", "replace")[:300].replace(key, "[key]")
            if error.code in (429, 500, 502, 503) and attempt < 2:
                time.sleep(1.5 * (attempt + 1))
                continue
            raise SystemExit(f"HTTP {error.code}: {message}")
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt < 2:
                time.sleep(1.5 * (attempt + 1))
                continue
            raise SystemExit(f"連線失敗：{error}")


partial_count = sum(1 for r in requests if r["kind"] == "partial")
print(f"{run.name}［{label}］：{len(segments)} 段、{len(requests)} 個翻譯請求（定稿 {len(segments)}、暫定 {partial_count}）")
if dry_run:
    for segment in segments:
        print(f"  {segment['t']:7.2f} {segment['reason']:6} {segment['text']}")
    sys.exit(0)

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
    results = list(pool.map(translate, requests))
for request, result in zip(requests, results):
    request.update(result)

# ---------------------------------------------------------------- 指標

finals = {r["segment"]: r for r in requests if r["kind"] == "final"}
partials = {}
for r in requests:
    if r["kind"] == "partial":
        partials.setdefault(r["segment"], []).append(r)

ready, shown_done, first_zh, first_zh_final_only, luna_first, luna_total = [], [], [], [], [], []
for index, s in enumerate(run.sentences):
    hits = run.sentence_words.get(index)
    if not hits:
        continue
    first_word, last_word = run.words[min(hits)], run.words[max(hits)]
    if "segment" not in last_word or "segment" not in first_word:
        continue
    final = finals[last_word["segment"]]
    ready.append(final["t"] - s["end"])                       # 英文這一段確定的時間
    shown_done.append(final["t"] + final["total"] - s["end"])  # 中文定稿完整出現
    # 第一個中文字：涵蓋這一句第一個字的請求裡，最早吐出第一個字的
    candidates = [finals[first_word["segment"]]["t"] + finals[first_word["segment"]]["first"]]
    first_zh_final_only.append(candidates[0] - s["start"])
    for partial in partials.get(first_word["segment"], []):
        if partial["t"] >= first_word["t"]:
            candidates.append(partial["t"] + partial["first"])
    first_zh.append(min(candidates) - s["start"])
for r in requests:
    luna_first.append(r["first"])
    luna_total.append(r["total"])

print(f"  （以下都以稿子的 {len(ready)} 句為單位；時間從音訊的時間點算起）")
describe("英文這一句確定（可以送翻譯）— 距離說完", ready)
describe("中文定稿完整出現 — 距離說完", shown_done)
describe("第一個中文字 — 距離開始說" + ("（含暫定譯文）" if with_partials else ""), first_zh)
if with_partials:
    describe("第一個中文字 — 距離開始說（沒有暫定譯文時）", first_zh_final_only)
describe("文字模型：第一個字", luna_first)
describe("文字模型：整段完成", luna_total)

if with_partials:
    # 暫定譯文的穩定度：下一版保留了上一版開頭的多少比例
    kept = []
    for segment_index, items in partials.items():
        chain = [p["zh"] for p in items] + [finals[segment_index]["zh"]]
        for previous, current in zip(chain, chain[1:]):
            if not previous:
                continue
            common = 0
            for a, b in zip(previous, current):
                if a != b:
                    break
                common += 1
            kept.append(common / len(previous))
    if kept:
        print(f"  暫定譯文改版時，開頭保留的比例：平均 {statistics.mean(kept) * 100:.0f}%、中位數 {statistics.median(kept) * 100:.0f}%（{len(kept)} 次改版；100% 表示只往後加字）")

tokens_in, tokens_out = sum(r["in"] for r in requests), sum(r["out"] for r in requests)
audio_seconds = run.sentences[-1]["end"]
PRICES = {"gpt-6-luna": (0.10, 0.50), "gpt-6.1-terra": (1.0, 5.0), "gpt-6.2-sol": (2.0, 10.0)}
price_in, price_out = PRICES.get(model, (0, 0))
cost = (tokens_in * price_in + tokens_out * price_out) / 1e6
print(f"  token：輸入 {tokens_in}、輸出 {tokens_out}；這次 {cost:.4f} 美元，換算每小時音訊約 {cost / audio_seconds * 3600:.3f} 美元（{model}）")

out_dir = f"{run.run_dir}/pipeline-{label}"
os.makedirs(out_dir, exist_ok=True)
translation = "\n".join(finals[i]["zh"] for i in sorted(finals))
open(f"{out_dir}/translation.txt", "w", encoding="utf-8").write(translation + "\n")
json.dump({"translated_text": translation, "source_text": stream,
           "config": {"model": model, "effort": effort, "trigger": trigger_mode, "partials": with_partials,
                      "partial_words": partial_words, "partial_interval": partial_interval}},
          open(f"{out_dir}/summary.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
json.dump({"segments": segments, "requests": requests,
           "metrics": {"ready": ready, "final_shown": shown_done, "first_zh": first_zh, "first_zh_final_only": first_zh_final_only,
                       "luna_first": luna_first, "luna_total": luna_total, "tokens_in": tokens_in, "tokens_out": tokens_out}},
          open(f"{out_dir}/pipeline.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
if show:
    for segment_index in sorted(finals):
        final = finals[segment_index]
        print(f"\n  [{final['t']:7.2f} {segments[segment_index]['reason']}] {final['text']}")
        for partial in partials.get(segment_index, []):
            print(f"      暫定 {partial['t']:7.2f}＋{partial['first']:.2f}  {partial['text']}\n           → {partial['zh']}")
        print(f"      定稿 {final['t']:7.2f}＋{final['total']:.2f}  {final['zh']}")
