#!/usr/bin/env python3
"""從 AMI 會議語料庫（CC BY 4.0）的人工逐字稿做參考稿，並切出同一段時間的音檔。（探索用）

用法：ami-reference.py <words 資料夾> <會議代號> <開始秒> <結束秒> <輸出.json> [--audio <會議.wav> <切出來的.wav>]

- 逐字稿：ami_public_manual_1.6.2.zip 裡的 words/<會議>.<講者>.words.xml（NXT 格式，每位講者一個檔）。
- 取出開始時間落在 [開始秒, 結束秒) 的字，依開始時間排序（多人同時說話時交錯排列），時間減掉開始秒，和切出來的音檔對齊。
- 標點是 punc="true" 的字，留著算句子的邊界；截斷的字（trunc="true"）不算。
- 輸出：{"meeting", "start", "end", "duration", "words": [{"w", "start", "end", "speaker", "punc"}]}

AMI 的音檔：https://groups.inf.ed.ac.uk/ami/download/（Mix-Headset 是各人耳麥混音，16 kHz）。
音檔與逐字稿都不進 repo（放在 Benchmarks/private/）。
"""
import glob
import json
import os
import sys
import wave
import xml.etree.ElementTree as ET

if len(sys.argv) < 6:
    sys.exit(__doc__)
folder, meeting, start, end, destination = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]

words = []
for path in sorted(glob.glob(os.path.join(folder, f"{meeting}.*.words.xml"))):
    speaker = path.split(".")[-3]
    for element in ET.parse(path).getroot().iter():
        if element.tag != "w" or element.get("trunc") == "true" or element.get("starttime") is None:
            continue
        begin, finish = float(element.get("starttime")), float(element.get("endtime") or element.get("starttime"))
        if not start <= begin < end:
            continue
        text = (element.text or "").strip()
        if text:
            words.append({"w": text, "start": round(begin - start, 3), "end": round(finish - start, 3),
                          "speaker": speaker, "punc": element.get("punc") == "true"})
words.sort(key=lambda word: (word["start"], word["end"]))
with open(destination, "w", encoding="utf-8") as output:
    json.dump({"meeting": meeting, "start": start, "end": end, "duration": end - start, "words": words}, output, ensure_ascii=False)
spoken = [word for word in words if not word["punc"]]
print(f"{meeting} {start:.0f}–{end:.0f} 秒：{len(spoken)} 個字、{len(words) - len(spoken)} 個標點、{len({w['speaker'] for w in spoken})} 位講者")

if "--audio" in sys.argv:
    source, target = sys.argv[sys.argv.index("--audio") + 1], sys.argv[sys.argv.index("--audio") + 2]
    with wave.open(source) as reader:
        rate, width, channels = reader.getframerate(), reader.getsampwidth(), reader.getnchannels()
        reader.setpos(int(start * rate))
        frames = reader.readframes(int((end - start) * rate))
    with wave.open(target, "wb") as writer:
        writer.setnchannels(channels)
        writer.setsampwidth(width)
        writer.setframerate(rate)
        writer.writeframes(frames)
    print(f"切出 {target}（{rate} Hz）")
