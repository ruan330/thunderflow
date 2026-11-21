#!/usr/bin/env python3
"""幫真實錄音做一份「參考稿」：用檔案轉錄（whisper-1，逐字時間戳）取得每個字的時間，再切成句子。（探索用）

用法：reference.py <音檔.wav> <輸出.json>

輸出的格式和 thunderbench synth 的 clip.json 相同（duration、sentences：start、end、text），
所以 transcript-latency.py 與 pipeline.py 可以直接拿來算延遲。

注意：這份參考稿是另一個模型聽出來的，不是人工校對的。
- 拿它算出來的「錯字率」其實是兩個模型之間的差異，只能用來互相比較，不能當成真正的錯字率。
- 逐字時間戳有零點幾秒的誤差，所以延遲的數字比合成語音的不準。
從環境變數 OPENAI_API_KEY 讀金鑰（不會印出）。會產生 API 費用（每分鐘 0.006 美元）。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
import wave

source, destination = sys.argv[1], sys.argv[2]
key = os.environ["OPENAI_API_KEY"].strip()
audio = open(source, "rb").read()
duration = wave.open(source, "rb").getnframes() / wave.open(source, "rb").getframerate()

boundary = uuid.uuid4().hex
parts = []
for name, value in (("model", "whisper-1"), ("response_format", "verbose_json"), ("language", "en"),
                    ("timestamp_granularities[]", "word"), ("timestamp_granularities[]", "segment")):
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + audio + b"\r\n")
parts.append(f"--{boundary}--\r\n".encode())
request = urllib.request.Request(
    "https://api.openai.com/v1/audio/transcriptions", data=b"".join(parts),
    headers={"Authorization": f"Bearer {key}", "Content-Type": f"multipart/form-data; boundary={boundary}"})
try:
    with urllib.request.urlopen(request, timeout=600) as response:
        result = json.load(response)
except urllib.error.HTTPError as error:
    sys.exit(f"HTTP {error.code}: {error.read().decode('utf-8', 'replace')[:300].replace(key, '[key]')}")

# 原始回應另外存一份，之後要換切句的方法不用再呼叫一次
json.dump(result, open(destination + ".raw.json", "w", encoding="utf-8"), ensure_ascii=False)
words = result.get("words") or []
text = result.get("text", "")


def normalize(word):
    return re.sub(r"[^a-z0-9%]", "", word.lower())


# 全文裡的每個字（帶標點）對上時間戳裡的每個字（不帶標點）
tokens = [t for t in text.split() if normalize(t)]
timed = [w for w in words if normalize(w.get("word", ""))]
sentences, current = [], []
position = 0
for token in tokens:
    # 往後找第一個正規化後相同的字；找不到就沿用上一個字的時間
    match = None
    for look in range(position, min(position + 6, len(timed))):
        if normalize(timed[look]["word"]) == normalize(token):
            match = look
            break
    if match is not None:
        start, end = timed[match]["start"], timed[match]["end"]
        position = match + 1
    elif current:
        start = end = current[-1][2]
    else:
        start = end = timed[position]["start"] if position < len(timed) else 0.0
    current.append((token, start, end))
    if re.search(r"[.?!][\"'”’)]*$", token):
        sentences.append(current)
        current = []
if current:
    sentences.append(current)

output = {
    "duration": round(duration, 3), "source": os.path.basename(source), "reference_model": "whisper-1",
    "sentences": [{"index": index, "start": round(items[0][1], 3), "end": round(items[-1][2], 3),
                   "text": " ".join(token for token, _, _ in items)} for index, items in enumerate(sentences)],
    # 每個字的時間（依序對應 sentences 裡的字），讓分析可以算到「字」而不只是「句」
    "words": [{"w": token, "start": round(start, 3), "end": round(end, 3), "sentence": index}
              for index, items in enumerate(sentences) for token, start, end in items],
}
json.dump(output, open(destination, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
lengths = [s["end"] - s["start"] for s in output["sentences"]]
print(f"{destination}: {len(output['sentences'])} 句、{len(tokens)} 個字、{duration:.0f} 秒；句長中位數 {sorted(lengths)[len(lengths) // 2]:.1f} 秒、最長 {max(lengths):.1f} 秒")
