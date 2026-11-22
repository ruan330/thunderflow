#!/usr/bin/env python3
"""暫定譯文策略的重播模擬（HANDOVER.md P11、Benchmarks/results/m2-provisional-report.md）。

用錄好的英文時間軸（thunderbench live --events 的 source_delta／source_end），在虛擬時間裡重播
不同的暫定譯文做法：請求真的送到 API，回來的時間＝送出的時間＋實測的請求時間。

用法：
  sim.py real <events.jsonl>                              正式引擎的事件重建畫面，算指標
  sim.py run <events.jsonl> <策略> [--limit N] [--words W] [--interval S] [--model M] [--tag X]
策略：p0（D32：逐段的暫定譯文＋段的定稿＋整句定稿）、s1（整句的暫定譯文）、
      s2（s1＋告訴模型畫面上已經有的中文，請它一字不改地保留）、s2r（s2，但翻錯或接不通順時可以改：D33 採用）、
      s3（s2＋照英文的語序翻）、s2f／s3f（整句定稿也請模型保留暫定譯文）
  sim.py post <out/策略.json> <顯示方式…>                事後換顯示方式（mask2、la2、hold6），不呼叫 API
Key 從環境變數 OPENAI_API_KEY 讀。結果寫到工作資料夾（環境變數 SIM_WORK，預設是目前的資料夾）的 out/<策略>.json，
API 的回應存在那裡的 cache.json（重跑不再花錢）。這兩個都不要放進 repo。
其他參數：--stream 1（邊收邊顯示）、--first-words N（每句第一個請求提早送）、--final-model、--tier priority。
前文和正式引擎一樣，只帶請求當下已經翻好的句子（定稿出現的時間取自事件檔）。
"""
import hashlib
import heapq
import json
import os
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.abspath(os.environ.get("SIM_WORK", "."))
CACHE_PATH = os.path.join(HERE, "cache.json")
KEY = os.environ.get("OPENAI_API_KEY", "")
PRICES = {"gpt-6-luna": (0.10, 0.50), "gpt-6.1-terra": (1.0, 5.0), "gpt-6.2-sol": (2.0, 10.0)}

lock = threading.Lock()
try:
    cache = json.load(open(CACHE_PATH, encoding="utf-8"))
except FileNotFoundError:
    cache = {}
spent = {"input": 0, "output": 0, "calls": 0, "cached": 0, "dollars": 0.0}


def save_cache():
    with lock:
        tmp = CACHE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False)
        os.replace(tmp, CACHE_PATH)


def masked(text):
    return re.sub(r"sk-[A-Za-z0-9_-]{6,}", "sk-***", text)


def call(instructions, text, model, max_tokens=400, tier=None):
    key = hashlib.sha256(json.dumps([model, instructions, text, max_tokens] + ([tier] if tier else []), ensure_ascii=False).encode()).hexdigest()
    with lock:
        if key in cache:
            spent["cached"] += 1
            return cache[key]
    body = {"model": model, "instructions": instructions, "input": text, "stream": True,
            "max_output_tokens": max_tokens, "reasoning": {"effort": "none"}}
    if tier:
        body["service_tier"] = tier
    data = json.dumps(body).encode()
    for attempt in range(5):
        request = urllib.request.Request(
            "https://api.openai.com/v1/responses", data=data,
            headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
        started, first, out, usage, pieces = time.monotonic(), None, [], {}, []
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
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
                        pieces.append((round(time.monotonic() - started, 3), event.get("delta", "")))
                    elif kind == "response.completed":
                        usage = event.get("response", {}).get("usage") or {}
                    elif kind in ("error", "response.failed", "response.incomplete"):
                        raise RuntimeError(payload[:300])
            total = time.monotonic() - started
            result = {"text": "".join(out).strip(), "first": first if first is not None else total, "total": total,
                      "in": usage.get("input_tokens", 0), "out": usage.get("output_tokens", 0), "pieces": pieces,
                      "tier": (usage and tier) or None}
            price_in, price_out = PRICES.get(model, (0.10, 0.50))
            with lock:
                cache[key] = result
                spent["input"] += result["in"]
                spent["output"] += result["out"]
                spent["calls"] += 1
                spent["dollars"] += (result["in"] * price_in + result["out"] * price_out) / 1e6
            return result
        except (urllib.error.URLError, RuntimeError, TimeoutError, ConnectionError, json.JSONDecodeError) as error:
            if attempt == 4:
                raise
            print("  重試：" + masked(str(error))[:160], file=sys.stderr, flush=True)
            time.sleep(1 + attempt * 2)


# MARK: 提示（和 TranslationPlanner 相同的規則）

TAIWAN = "使用台灣的用語與技術詞彙（例如：推論、伺服器、資料、軟體、預設、端點、可用區域、無伺服器、記憶體、權杖或 token）。"
NAMES = "產品名稱與專有名詞保留英文原文，不要翻譯也不要拆開（例如 Amazon Bedrock、AgentCore、Graviton5、microVM、S3 Vectors、CloudWatch）。"
STYLE = "數字用阿拉伯數字。語氣自然、精簡，像字幕。"
FILLERS = "這是現場的口語：去掉 uh、um、you know、I mean，以及當口頭禪用的 right、like、so，還有重複的字和說到一半改口的部分，只留下講者要表達的意思。"


def segment_instructions(is_final):
    if is_final:
        lines = ["你是演講、課程與會議的即時字幕譯者。把使用者給的「這一段」英文翻成台灣繁體中文，供現場觀眾閱讀。"]
    else:
        lines = ["你是演講、課程與會議的即時字幕譯者。講者還沒說完，使用者給的是「目前聽到的部分」。把它翻成台灣繁體中文，供現場觀眾先看。"]
    lines += ["規則：", "1. " + TAIWAN, "2. " + NAMES, "3. " + STYLE]
    if is_final:
        lines += ["4. 這一段可能只是半句話：照聽到的內容翻譯，不要自行補完，也不要重複前文。", "5. 只輸出這一段的譯文，不要加任何說明。"]
    else:
        lines += ["4. 只翻譯已經聽到的內容，不要猜測或補完後面還沒說的部分，結尾不要加句號。", "5. 只輸出譯文，不要重複前文，不要加任何說明。"]
    return "\n".join(lines)


def segment_input(text, context, is_final):
    parts = []
    if context:
        parts.append("前文（只供參考，不要翻譯）：\n" + "\n".join(context))
    parts.append(("這一段：\n" if is_final else "目前聽到的部分：\n") + text)
    return "\n\n".join(parts)


def sentence_instructions(keep_shown=False):
    lines = [
        "你是演講、課程與會議的即時字幕譯者。把使用者給的「這一句」英文翻成台灣繁體中文，供現場觀眾閱讀。",
        "規則：",
        "1. 譯成通順、自然的中文句子：依中文的語序重新組織，不要照英文的順序逐字翻。",
        "2. " + FILLERS,
        "3. 「前文」是剛才的英文和已經顯示給觀眾的中文：用語與稱呼要和前文的中文一致，接得上前文，但不要重複前文已經翻過的內容。",
        "4. " + TAIWAN, "5. " + NAMES, "6. " + STYLE,
        "7. 只輸出這一句的譯文，不要加任何說明。",
    ]
    if keep_shown:
        lines.append("8. 「畫面上的暫定譯文」是觀眾剛才看到的這一句的譯文。它的開頭如果正確又通順，請盡量原樣保留，避免畫面上的字大幅改變；但正確與通順優先。")
    return "\n".join(lines)


def partial_instructions(keep_shown=False, linear=False, relaxed=False):
    lines = [
        "你是演講、課程與會議的即時字幕譯者。講者這一句還沒說完，使用者給的是「這一句目前聽到的部分」。把它翻成台灣繁體中文，供現場觀眾先看。",
        "規則：",
        "1. 譯成通順、自然的中文：依中文的語序組織，但只翻已經聽到的內容，不要猜測或補完還沒說的部分。",
        "2. " + FILLERS,
        "3. 「前文」是剛才的英文和已經顯示給觀眾的中文：用語與稱呼要和前文的中文一致，但不要重複前文已經翻過的內容。",
        "4. " + TAIWAN, "5. " + NAMES, "6. " + STYLE,
        "7. 結尾不要加句號。只輸出譯文，不要加任何說明。",
    ]
    if keep_shown and relaxed:
        lines.append("8. 「畫面上的暫定譯文」是觀眾正在看的這一句的譯文。請盡量一字不改地以它開頭，只在後面接上新聽到的部分；但如果它翻錯了，或照著它接下去會不通順，就修改它。")
    elif keep_shown:
        lines.append("8. 「畫面上的暫定譯文」是觀眾正在看的這一句的譯文。除非它翻錯了，否則請一字不改地以它開頭，只在後面接上新聽到的部分。")
    if linear:
        lines.append("9. 像同步口譯一樣：盡量依英文的順序往下翻，讓後面新聽到的內容可以直接接在後面，不要把前面的字搬到後面。")
    return "\n".join(lines)


def sentence_input(english, context, label, shown=None):
    parts = []
    if context:
        lines = [f"英：{en}\n中：{zh}" if zh else f"英：{en}" for en, zh in context]
        parts.append("前文（只供參考，不要翻譯）：\n" + "\n".join(lines))
    if shown:
        parts.append("畫面上的暫定譯文：\n" + shown)
    parts.append(f"{label}：\n" + english)
    return "\n\n".join(parts)


# MARK: 時間軸

def words(text):
    total = 0.0
    for token in text.split():
        ideographs = sum(1 for ch in token if 0x4E00 <= ord(ch) <= 0x9FFF or 0x3400 <= ord(ch) <= 0x4DBF)
        other = any(ch.isalnum() and not (0x4E00 <= ord(ch) <= 0x9FFF or 0x3400 <= ord(ch) <= 0x4DBF) for ch in token)
        total += ideographs / 2 + (1 if other else 0)
    return total


def ends_sentence(text):
    text = text.rstrip().rstrip("\"'”’)]}」』）】》").rstrip()
    return bool(text) and text[-1] in ".?!。？！"


def join(parts):
    result = ""
    for part in parts:
        piece = part.strip()
        if not piece:
            continue
        if result and (result[-1].isascii() and result[-1].isalnum()) and (piece[0].isascii() and piece[0].isalnum()):
            result += " "
        result += piece
    return result


def shown_form(text):
    """畫面上的樣子：句尾的「。」不顯示（D32）。"""
    text = text.strip()
    return text[:-1] if text.endswith("。") else text


def load(path):
    segs, finals = {}, {}
    for line in open(path, encoding="utf-8"):
        e = json.loads(line)
        n, kind = e.get("segment"), e["kind"]
        if kind in ("source_delta", "source_end") and n is not None:
            s = segs.setdefault(n, {"n": n, "deltas": [], "end": None, "final": "", "sentence": None})
            if e.get("sentence") is not None:
                s["sentence"] = e["sentence"]
            if kind == "source_delta":
                s["deltas"].append((e["t"], e["text"]))
            else:
                if s["end"] is None:
                    s["end"] = e["t"]
                s["final"] = e["text"]
        elif kind == "translation" and e.get("first") is not None:
            finals.setdefault(e["sentence"], (e["t"], e["text"]))
    # 晚到的尾巴被併回上一段（Segmenter 的 extended）：下一段在那之前收到的字其實是上一段的尾巴，
    # 正式引擎會在那時清掉進行中的文字，這裡也把它們從下一段拿掉
    ends_at = {}
    for line in open(path, encoding="utf-8"):
        e = json.loads(line)
        if e["kind"] == "source_end" and e.get("segment") is not None:
            ends_at.setdefault(e["segment"], []).append(e["t"])
    for n, s in segs.items():
        if not s["deltas"] or (n - 1) not in ends_at:
            continue
        first_delta = s["deltas"][0][0]
        later = [t for t in ends_at[n - 1] if t > first_delta]
        if later:
            cut = max(later)
            s["deltas"] = [(t, d) for t, d in s["deltas"] if t > cut]
    sentences = {}
    for n in sorted(segs):
        s = segs[n]
        if s["sentence"] is None or s["end"] is None or not s["deltas"]:
            continue
        sentences.setdefault(s["sentence"], []).append(n)
    out = []
    for number in sorted(sentences):
        members = sentences[number]
        points, done = [], []
        for n in members:
            cum = ""
            for t, d in segs[n]["deltas"]:
                cum += d
                points.append((t, join([segs[m]["final"] for m in done] + [cum]), n))
            done.append(n)
            points.append((segs[n]["end"], join([segs[m]["final"] for m in done]), None))
        last = segs[members[-1]]
        english = join([segs[m]["final"] for m in members])
        close = last["end"] if ends_sentence(last["final"]) else last["end"] + 2.5
        out.append({"number": number, "members": members, "points": points, "english": english,
                    "start": points[0][0], "close": close, "recorded_final": finals.get(number)})
    return segs, out


def word_times(sentence):
    """第 i 個英文字出現的時間（i 從 1 開始）。"""
    times, count = [], 0
    for t, text, _ in sentence["points"]:
        w = int(words(text))
        while count < w:
            count += 1
            times.append(t)
    return times


# MARK: 模擬

def contexts(sentences):
    """每一句的前文：前三句的英文、錄下來的整句定稿，以及定稿出現的時間（和正式引擎一樣，只帶請求當下已經翻好的）。"""
    result, recent = {}, []
    for s in sentences:
        result[s["number"]] = list(recent[-3:])
        final = s["recorded_final"]
        recent.append((s["english"], final[1] if final else None, final[0] if final else None))
    return result


def context_at(context, t):
    """時間 t 送出的請求帶的前文：只帶已經翻好的句子（TranslationPlanner 的暫定譯文同樣如此）。"""
    return [(en, zh) for en, zh, at in context if zh and at is not None and at <= t]


def run_sentence_level(sentence, context, strategy):
    model, n_words, interval = strategy["model"], strategy["words"], strategy["interval"]
    keep = strategy["name"] in ("s2", "s2f", "s3", "s3f", "s2r")
    instructions = partial_instructions(keep_shown=keep, linear=strategy["name"] in ("s3", "s3f"), relaxed=strategy["name"] == "s2r")
    tier = strategy.get("tier")
    close, points = sentence["close"], sentence["points"]
    shown, display, requests = "", [], 0
    busy_until, pending = None, None
    last_t, last_w = -1e9, 0.0
    i, current, current_w = 0, "", 0.0
    while True:
        t_point = points[i][0] if i < len(points) else None
        candidates = [x for x in (t_point, busy_until) if x is not None and x < close]
        if not candidates:
            break
        t = min(candidates)
        if busy_until is not None and t == busy_until:
            result, covered = pending
            busy_until, pending = None, None
            out = result["text"].strip()
            if out and out != shown:
                shown = out
                display.append((t, out, covered, "gray"))
        else:
            current = points[i][1]
            current_w = words(current)
            i += 1
        first_words = strategy.get("first_words")
        due = (current_w - last_w >= n_words and t - last_t >= interval) or (
            first_words is not None and requests == 0 and current_w >= first_words)
        if busy_until is None and due:
            result = call(instructions, sentence_input(current, context_at(context, t), "這一句目前聽到的部分", shown if keep else None), model, tier=tier)
            requests += 1
            busy_until, pending = t + result["total"], (result, current_w)
            last_t, last_w = t, current_w
            if strategy.get("stream") and result.get("pieces"):
                # 邊收邊顯示：只要收到的字接得上畫面上的字（畫面上的字是它的開頭），就先顯示；接不上就等完整回來再換
                final_text, cum, last_shown = result["text"].strip(), "", shown
                for dt, piece in result["pieces"]:
                    if t + dt >= close:
                        break  # 一句說完時這個請求就取消了
                    cum += piece
                    body = cum.strip()
                    if not body or last_shown.startswith(body):
                        continue
                    if body.startswith(last_shown) and body != last_shown:
                        display.append((t + dt, body, current_w * len(body) / max(1, len(final_text)), "gray"))
                        last_shown = body
                    elif not body.startswith(last_shown):
                        break
    keep_final = strategy["name"] in ("s2f", "s3f")
    final = call(sentence_instructions(keep_shown=keep_final),
                 sentence_input(sentence["english"], [(en, zh) for en, zh, _ in context], "這一句", shown if keep_final else None),
                 strategy.get("final_model", model), tier=tier)
    display.append((close + final["total"], final["text"].strip(), words(sentence["english"]), "white"))
    return display, requests


def run_segment_level(sentence, segs, strategy):
    """現在的做法：進行中的這一段每 3 個字、至少隔 1 秒送一次暫定譯文；段結束時送段的定稿（一句的最後一段除外）；一句說完送整句定稿。"""
    model, n_words, interval = strategy["model"], strategy["words"], strategy["interval"]
    members = sentence["members"]
    order = sorted(segs)
    close = sentence["close"]
    idle_closed = close > segs[members[-1]]["end"] + 0.01
    heap, seq = [], 0

    def push(t, kind, payload):
        nonlocal seq
        heapq.heappush(heap, (t, seq, kind, payload))
        seq += 1

    for n in members:
        cum = ""
        for t, d in segs[n]["deltas"]:
            cum += d
            push(t, "point", (n, cum.strip()))
        push(segs[n]["end"], "end", n)
    shown_part, cover, display, requests = {}, {}, [], 0
    live = {"n": None, "text": "", "busy": None, "last_t": -1e9, "last_w": 0.0}

    def history(n):
        index = order.index(n)
        return [segs[m]["final"] for m in order[max(0, index - 2):index]]

    def compose(t, kind="gray"):
        text = join([shown_part.get(m, "") for m in members])
        covered = sum(cover.get(m, 0) for m in members)
        if text and (not display or display[-1][1] != text):
            display.append((t, text, covered, kind))

    def try_start(t):
        nonlocal requests
        if live["n"] is None or live["busy"] is not None:
            return
        w = words(live["text"])
        if w - live["last_w"] >= n_words and t - live["last_t"] >= interval:
            n = live["n"]
            result = call(segment_instructions(False), segment_input(live["text"], history(n), False), model)
            requests += 1
            live["busy"] = (t + result["total"], result)
            live["last_t"], live["last_w"] = t, w
            push(t + result["total"], "pdone", (n, result, w))
            if n not in shown_part and result.get("pieces"):
                cum, final_text = "", result["text"].strip()
                for dt, piece in result["pieces"]:
                    cum += piece
                    if cum.strip():
                        push(t + dt, "pstream", (n, result, cum.strip(), w * len(cum.strip()) / max(1, len(final_text))))

    final_result = None
    white_at = None
    while heap:
        t, _, kind, payload = heapq.heappop(heap)
        if white_at is not None and t >= white_at:
            break
        if t >= close and final_result is None:
            final_result = call(sentence_instructions(), sentence_input(sentence["english"], [(en, zh) for en, zh, _ in sentence["context"]], "這一句"),
                                strategy.get("final_model", model))
            white_at = close + final_result["total"]
            if t >= white_at:
                break
        if kind == "point":
            n, text = payload
            if live["n"] != n:
                live.update({"n": n, "text": text, "busy": None, "last_t": -1e9, "last_w": 0.0})
            live["text"] = text
            try_start(t)
        elif kind == "end":
            n = payload
            live.update({"n": None, "busy": None})
            if n != members[-1] or idle_closed:
                result = call(segment_instructions(True), segment_input(segs[n]["final"], history(n), True), model)
                requests += 1
                push(t + result["total"], "fdone", (n, result))
        elif kind == "pdone":
            n, result, w = payload
            if live["n"] == n and live["busy"] is not None and live["busy"][1] is result:
                live["busy"] = None
                out = result["text"].strip()
                if out and not shown_part.get(("final", n)):
                    shown_part[n] = out
                    cover[n] = w
                    compose(t)
                try_start(t)
        elif kind == "pstream":
            n, result, partial, w = payload
            if live["n"] == n and live["busy"] is not None and live["busy"][1] is result and not shown_part.get(("final", n)):
                shown_part[n] = partial
                cover[n] = w
                compose(t)
        elif kind == "fdone":
            n, result = payload
            out = result["text"].strip()
            if out:
                shown_part[n] = out
                shown_part[("final", n)] = True
                cover[n] = words(segs[n]["final"])
                compose(t)
    if final_result is None:
        final_result = call(sentence_instructions(), sentence_input(sentence["english"], [(en, zh) for en, zh, _ in sentence["context"]], "這一句"),
                            strategy.get("final_model", model))
        white_at = close + final_result["total"]
    display = [d for d in display if d[0] < white_at]
    display.append((white_at, final_result["text"].strip(), words(sentence["english"]), "white"))
    # 合成用的 key 不能出現在 join 裡
    return display, requests


# MARK: 指標

def lcp(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def metrics(sentence, display):
    texts = sorted(((t, shown_form(text), covered, kind) for t, text, covered, kind in display if shown_form(text)),
                   key=lambda d: d[0])
    final = texts[-1][1] if texts else ""
    first_zh = (texts[0][0] - sentence["start"]) if texts else None
    erased, rewrites, updates, erased_gray, erased_final, gray_rewrites = 0, 0, 0, 0, 0, 0
    previous = ""
    for _, text, _, kind in texts:
        if text == previous:
            continue
        removed = len(previous) - lcp(previous, text)
        if removed > 0:
            erased += removed
            rewrites += 1
            if kind == "white":
                erased_final += removed
            else:
                erased_gray += removed
                gray_rewrites += 1
        updates += 1
        previous = text
    whites = [t for t, _, _, kind in texts if kind == "white"]
    lags = []
    times = word_times(sentence)
    for index, heard in enumerate(times, start=1):
        seen = [t for t, _, covered, _ in texts if covered >= index - 1e-9]
        if seen:
            lags.append(min(seen) - heard)
    return {"first_zh": first_zh, "erased": erased, "ne": erased / max(1, len(final)), "rewrites": rewrites,
            "ne_gray": erased_gray / max(1, len(final)), "ne_final": erased_final / max(1, len(final)),
            "gray_rewrites": gray_rewrites,
            "updates": updates, "final_delay": (whites[0] - sentence["close"]) if whites else None, "lags": lags,
            "final": final}


def pct(values, q):
    values = sorted(v for v in values if v is not None)
    return values[min(len(values) - 1, int(len(values) * q))] if values else float("nan")


def summarize(results):
    first = [r["m"]["first_zh"] for r in results]
    lags = [x for r in results for x in r["m"]["lags"]]
    return {
        "sentences": len(results),
        "first_zh_median": pct(first, 0.5), "first_zh_p90": pct(first, 0.9),
        "lag_median": pct(lags, 0.5), "lag_p90": pct(lags, 0.9),
        "ne_mean": statistics.mean(r["m"]["ne"] for r in results) if results else 0,
        "rewritten": sum(1 for r in results if r["m"]["rewrites"] > 0) / max(1, len(results)),
        "rewrites_per_sentence": statistics.mean(r["m"]["rewrites"] for r in results) if results else 0,
        "ne_gray": statistics.mean(r["m"].get("ne_gray", 0) for r in results) if results else 0,
        "ne_final": statistics.mean(r["m"].get("ne_final", 0) for r in results) if results else 0,
        "gray_rewrites": statistics.mean(r["m"].get("gray_rewrites", 0) for r in results) if results else 0,
        "updates_per_sentence": statistics.mean(r["m"]["updates"] for r in results) if results else 0,
        "final_delay_median": pct([r["m"]["final_delay"] for r in results], 0.5),
        "final_delay_p90": pct([r["m"]["final_delay"] for r in results], 0.9),
        "requests": sum(r["requests"] for r in results),
    }


def show(name, summary, extra=""):
    s = summary
    print(f"{name:<14} 句 {s['sentences']:>3}｜第一個中文字 {s['first_zh_median']:.2f}／{s['first_zh_p90']:.2f} 秒"
          f"｜每個字的延遲 {s['lag_median']:.2f}／{s['lag_p90']:.2f} 秒｜被擦掉的字 {s['ne_mean'] * 100:.0f}%"
          f"（灰字之間 {s['ne_gray'] * 100:.0f}%、換白字 {s['ne_final'] * 100:.0f}%）"
          f"｜改寫過的句 {s['rewritten'] * 100:.0f}%（灰字之間每句 {s['gray_rewrites']:.1f} 次）"
          f"｜白字 {s['final_delay_median']:.2f}／{s['final_delay_p90']:.2f} 秒｜請求 {s['requests']} {extra}")


# MARK: 正式引擎的事件

def real(path):
    segs, sentences = load(path)
    by_segment = {}
    events = [json.loads(line) for line in open(path, encoding="utf-8")]
    results = []
    index = {s["number"]: s for s in sentences}
    displays = {s["number"]: [] for s in sentences}
    part = {}
    owner = {n: s["number"] for s in sentences for n in s["members"]}
    draft_text = {}
    for e in events:
        n = e.get("segment")
        if e["kind"] == "provisional" and e.get("first") is not None and e.get("sentence") in displays:
            # 整句的暫定譯文：這一句的灰字就是它
            number = e["sentence"]
            if not any(kind == "white" for _, _, _, kind in displays[number]):
                draft_text[number] = e["text"]
                displays[number].append((e["t"], e["text"], 0, "gray"))
            continue
        if e["kind"] == "provisional" and n in owner and not part.get(("final", n)):
            part[n] = e["text"]
        elif e["kind"] == "translation" and e.get("first") is None and n in owner:
            part[n] = e["text"]
            part[("final", n)] = True
        elif e["kind"] == "translation" and e.get("first") is not None:
            number = e["sentence"]
            if number in displays:
                displays[number].append((e["t"], e["text"], 1e9, "white"))
            continue
        else:
            continue
        number = owner[n]
        if any(kind == "white" for _, _, _, kind in displays[number]) or number in draft_text:
            continue
        text = join([part.get(m, "") for m in index[number]["members"]])
        displays[number].append((e["t"], text, 0, "gray"))
    for s in sentences:
        d = displays[s["number"]]
        if not any(kind == "white" for _, _, _, kind in d):
            continue
        m = metrics(s, d)
        m["lags"] = []
        results.append({"number": s["number"], "m": m, "requests": 0, "display": d})
    return results


# MARK: 事後換顯示方式（不呼叫 API）

def apply_policy(display, policy):
    """display 是模擬出來的每一版（灰字的暫定譯文與最後的白字），回傳畫面上真正顯示的序列。"""
    grays = [d for d in display if d[3] == "gray"]
    whites = [d for d in display if d[3] == "white"]
    out = []
    if policy.startswith("mask"):
        k = int(policy[4:])
        for t, text, covered, kind in grays:
            body = shown_form(text)
            keep = body[:-k] if len(body) > k else ""
            out.append((t, keep, covered * len(keep) / max(1, len(body)), kind))
    elif policy == "la2":
        committed, previous = "", None
        for t, text, covered, kind in grays:
            body = shown_form(text)
            if previous is not None:
                c = lcp(previous, body)
                if c > len(committed) and body.startswith(committed):
                    committed = body[:c]
                    out.append((t, committed, covered * c / max(1, len(body)), kind))
            previous = body
    elif policy.startswith("hold"):
        jump = float(policy[4:] or 6)
        shown, shown_cover = "", 0.0
        for t, text, covered, kind in grays:
            body = shown_form(text)
            if not shown or body.startswith(shown) or covered - shown_cover >= jump:
                shown, shown_cover = body, covered
                out.append((t, body, covered, kind))
    else:
        out = list(grays)
    return [d for d in out if d[1]] + whites


def post(path, policy):
    data = json.load(open(path, encoding="utf-8"))
    segs, sentences = load(data["events"])
    index = {s["number"]: s for s in sentences}
    results = []
    for r in data["results"]:
        display = apply_policy([tuple(d) for d in r["display"]], policy)
        results.append({"number": r["number"], "m": metrics(index[r["number"]], display), "requests": r["requests"]})
    summary = summarize(results)
    show(os.path.basename(path)[:-5] + "+" + policy, summary)
    return summary


def main():
    args = sys.argv[1:]
    mode, path = args[0], args[1]
    if mode == "post":
        for policy in args[2:]:
            post(path, policy)
        return
    options = {"--limit": None, "--words": "3", "--interval": "1.0", "--model": "gpt-6-luna", "--tag": "",
               "--final-model": None, "--workers": "8", "--stream": "0", "--tier": None, "--first-words": None}
    rest = args[2:]
    strategy_name = rest.pop(0) if mode == "run" else None
    while rest:
        flag = rest.pop(0)
        options[flag] = rest.pop(0)
    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    if mode == "real":
        results = real(path)
        summary = summarize(results)
        show("正式引擎", summary)
        name = "real" + options["--tag"]
        json.dump({"summary": summary, "results": results}, open(os.path.join(HERE, "out", name + ".json"), "w"),
                  ensure_ascii=False)
        return
    segs, sentences = load(path)
    if options["--limit"]:
        sentences = sentences[: int(options["--limit"])]
    ctx = contexts(sentences)
    for s in sentences:
        s["context"] = ctx[s["number"]]
    strategy = {"name": strategy_name, "model": options["--model"], "words": float(options["--words"]),
                "interval": float(options["--interval"])}
    if options["--final-model"]:
        strategy["final_model"] = options["--final-model"]
    if options["--stream"] == "1":
        strategy["stream"] = True
    if options["--tier"]:
        strategy["tier"] = options["--tier"]
    if options["--first-words"]:
        strategy["first_words"] = float(options["--first-words"])

    def one(s):
        if strategy_name == "p0":
            display, requests = run_segment_level(s, segs, strategy)
        else:
            display, requests = run_sentence_level(s, s["context"], strategy)
        return {"number": s["number"], "m": metrics(s, display), "requests": requests, "display": display}

    started = time.monotonic()
    with ThreadPoolExecutor(int(options["--workers"])) as pool:
        results = list(pool.map(one, sentences))
    save_cache()
    summary = summarize(results)
    name = strategy_name + options["--tag"]
    show(name, summary, f"｜這次花 US${spent['dollars']:.3f}（新請求 {spent['calls']}、快取 {spent['cached']}），{time.monotonic() - started:.0f} 秒")
    json.dump({"strategy": strategy, "summary": summary, "results": results, "spent": spent, "events": os.path.abspath(path)},
              open(os.path.join(HERE, "out", name + ".json"), "w"), ensure_ascii=False)


if __name__ == "__main__":
    main()
