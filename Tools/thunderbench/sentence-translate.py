#!/usr/bin/env python3
"""M0 探索：用文字模型把英文一句一句翻成台灣繁體中文，量延遲並看品質。

用法：sentence-translate.py <clip.json> <模型> [reasoning effort]
從環境變數 OPENAI_API_KEY 讀金鑰（不會印出）。每句帶前兩句當上下文，以串流方式取得輸出。
"""
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

clip = json.load(open(sys.argv[1], encoding="utf-8"))
model = sys.argv[2]
effort = sys.argv[3] if len(sys.argv) > 3 else "none"
key = os.environ["OPENAI_API_KEY"].strip()

INSTRUCTIONS = (
    "你是技術研討會的即時字幕譯者。把使用者給的「這一句」英文翻成台灣繁體中文，供現場觀眾閱讀。\n"
    "規則：\n"
    "1. 使用台灣的用語與技術詞彙（例如：推論、伺服器、資料、軟體、預設、端點、可用區域、無伺服器、記憶體、權杖或 token）。\n"
    "2. 產品名稱與專有名詞保留英文原文，不要翻譯也不要拆開（例如 Amazon Bedrock、AgentCore、Graviton5、microVM、S3 Vectors、CloudWatch）。\n"
    "3. 數字用阿拉伯數字。語氣自然、精簡，像字幕。\n"
    "4. 只輸出這一句的譯文，不要重複前文，不要加任何說明。"
)


def translate(sentence, context):
    parts = []
    if context:
        parts.append("前文（只供參考，不要翻譯）：\n" + "\n".join(context))
    parts.append("這一句：\n" + sentence)
    body = {"model": model, "instructions": INSTRUCTIONS, "input": "\n\n".join(parts), "stream": True, "max_output_tokens": 300}
    if effort != "omit":
        body["reasoning"] = {"effort": effort}
    request = urllib.request.Request(
        "https://api.openai.com/v1/responses", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    start = time.monotonic()
    first = None
    text = ""
    usage = {}
    with urllib.request.urlopen(request, timeout=60) as response:
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
    return text.strip(), first, time.monotonic() - start, usage


sentences = [s["text"] for s in clip["sentences"]]
firsts, totals, tokens_in, tokens_out, out = [], [], 0, 0, []
try:
    for index, sentence in enumerate(sentences):
        text, first, total, usage = translate(sentence, sentences[max(0, index - 2):index])
        firsts.append(first if first is not None else total)
        totals.append(total)
        tokens_in += usage.get("input_tokens", 0)
        tokens_out += usage.get("output_tokens", 0)
        out.append(text)
        print(f"{index + 1:>2}  {first if first is not None else -1:5.2f}s / {total:5.2f}s  {text}")
except urllib.error.HTTPError as error:
    print("HTTP", error.code, error.read().decode("utf-8")[:300].replace(key, "[key]"))
    sys.exit(1)

p95 = lambda v: sorted(v)[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))]
print(f"\n{model}（reasoning {effort}）：第一個字 中位數 {statistics.median(firsts):.2f} 秒、P95 {p95(firsts):.2f}；整句完成 中位數 {statistics.median(totals):.2f} 秒、P95 {p95(totals):.2f}")
print(f"token：輸入 {tokens_in}、輸出 {tokens_out}（{len(sentences)} 句）")
json.dump({"model": model, "effort": effort, "first": firsts, "total": totals, "input_tokens": tokens_in, "output_tokens": tokens_out, "text": out},
          open(f"{os.path.dirname(sys.argv[1])}/runs/sentence-{os.path.basename(sys.argv[1]).split('.')[0]}-{model}.json", "w"), ensure_ascii=False, indent=1)
