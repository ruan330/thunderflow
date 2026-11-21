"""M0b 分析共用：讀一次執行的事件，把收到的英文字和稿子對齊。（探索用）

兩種連線的紀錄都能讀：
- translate 的輸出（事件 session.input_transcript.delta）
- transcribe 的輸出（事件 conversation.item.input_audio_transcription.delta／completed，以及用戶端的 commit 紀錄）

時間基準：rx_ms 是「從開始送音訊算起」收到事件的時間；以即時速度送音訊時，它等於當下已經播到的音訊位置。
對齊只看文字（序列比對），不依賴伺服器給的任何時間欄位。
"""
import difflib
import json
import re
import statistics

DELTA_TYPES = ("session.input_transcript.delta", "conversation.item.input_audio_transcription.delta")
COMPLETED_TYPE = "conversation.item.input_audio_transcription.completed"
TERMINATORS = ".?!"


def normalize(word):
    return re.sub(r"[^a-z0-9%]", "", word.lower())


def split_tokens(text):
    """連字號當成分隔（production-ready 與 production ready 視為相同）。"""
    return [w for w in re.split(r"[\s\-–—]+", text) if normalize(w)]


def pct(values, q):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def describe(name, values, unit="秒"):
    if not values:
        print(f"  {name}: 沒有資料")
        return
    print(f"  {name}: 中位數 {statistics.median(values):.2f} {unit}　P95 {pct(values, 0.95):.2f}　最小 {min(values):.2f}　最大 {max(values):.2f}　（{len(values)} 筆）")


class Run:
    def __init__(self, run_dir, clip_path, loops=0):
        self.run_dir = run_dir.rstrip("/")
        self.name = self.run_dir.split("/")[-1]
        self.events = [json.loads(line) for line in open(f"{self.run_dir}/events.jsonl", encoding="utf-8")]
        self.clip = json.load(open(clip_path, encoding="utf-8"))

        # --- 收到的文字：每個字元的到達時間與所屬的段（item） ---
        self.deltas = [(e["rx_ms"] / 1000, e["event"].get("delta", ""), e["event"].get("item_id"))
                       for e in self.events if e.get("event", {}).get("type") in DELTA_TYPES and "rx_ms" in e]
        if not self.deltas:
            raise SystemExit(f"{self.name}: 沒有英文逐字稿的事件")
        self.chars = []  # (char, rx, item)
        previous_item = None
        for rx, text, item in self.deltas:
            if not text:
                continue
            if previous_item is not None and item != previous_item and self.chars and not self.chars[-1][0].isspace() and not text[0].isspace():
                self.chars.append((" ", rx, item))  # 不同段之間補一個空白，避免前後兩個字黏在一起
            for ch in text:
                self.chars.append((ch, rx, item))
            previous_item = item
        self.stream = "".join(c for c, _, _ in self.chars)

        # --- 字：時間看最後一個字母或數字，不含黏在後面的標點（句號常常晚很多才到） ---
        self.words = []
        for match in re.finditer(r"[^\s\-–—]+", self.stream):
            norm = normalize(match.group())
            if not norm:
                continue
            end = match.end()
            while end > match.start() and not re.match(r"[A-Za-z0-9%]", self.stream[end - 1]):
                end -= 1
            self.words.append({"norm": norm, "t": self.chars[end - 1][1], "start": match.start(), "end": end, "item": self.chars[end - 1][2]})

        # --- 稿子：循環播放時把稿子接起來 ---
        duration = self.clip["duration"]
        last_rx = self.deltas[-1][0]
        if loops <= 0:
            loops = max(1, int(last_rx // duration) + (1 if last_rx % duration > 5 else 0))
        self.loops = loops
        self.sentences = [
            {"start": s["start"] + loop * duration, "end": s["end"] + loop * duration, "text": s["text"]}
            for loop in range(loops) for s in self.clip["sentences"]
        ]
        # 循環播放時最後一輪通常沒有播完：只保留整句都已經送出的句子
        try:
            sent = json.load(open(f"{self.run_dir}/summary.json", encoding="utf-8")).get("audio_sent_seconds")
        except (OSError, ValueError):
            sent = None
        if sent:
            self.sentences = [s for s in self.sentences if s["end"] <= sent + 0.05]
        self.reference = [(normalize(word), index) for index, s in enumerate(self.sentences) for word in split_tokens(s["text"])]
        # 真實錄音的參考稿（reference.py 產生）帶有每個字的時間：稿子的每個字何時說出來
        self.reference_times = None
        if self.clip.get("words") and loops == 1:
            self.reference, self.reference_times = [], []
            for item in self.clip["words"]:
                for word in split_tokens(item["w"]):
                    self.reference.append((normalize(word), item["sentence"]))
                    self.reference_times.append((item["start"], item["end"]))

        # --- 對齊 ---
        # 循環播放時一輪一輪對：同一份稿子重複出現，整段一起比對會對到別輪去。
        # 每一輪只拿「上一輪對完之後、這一輪結束後 3 秒以內」收到的字來比對。
        self.aligned = {}  # 稿子的第幾個字 -> 收到的第幾個字
        self.substitutions = self.deletions = self.insertions = 0
        self.differences = []
        per_loop = len(self.clip["sentences"])
        pointer = 0
        reference_offset = 0
        for loop in range(loops):
            loop_sentences = range(loop * per_loop, min((loop + 1) * per_loop, len(self.sentences)))
            reference = [(w, i) for w, i in self.reference if i in loop_sentences]
            if not reference:
                break
            is_last = loop == loops - 1 or (loop + 1) * per_loop >= len(self.sentences)
            limit = float("inf") if is_last else (loop + 1) * duration + 3.0
            stop = pointer
            while stop < len(self.words) and self.words[stop]["t"] < limit:
                stop += 1
            heard = self.words[pointer:stop]
            matcher = difflib.SequenceMatcher(a=[w for w, _ in reference], b=[w["norm"] for w in heard], autojunk=False)
            opcodes = matcher.get_opcodes()
            last_matched = -1
            for tag, a0, a1, b0, b1 in opcodes:
                if tag == "equal":
                    last_matched = b1 - 1
            for tag, a0, a1, b0, b1 in opcodes:
                if tag == "equal":
                    for k in range(a1 - a0):
                        self.aligned[reference_offset + a0 + k] = pointer + b0 + k
                    continue
                if not is_last and b0 > last_matched and a0 == a1:
                    continue  # 這一輪對完之後多出來的字屬於下一輪
                if tag == "replace":
                    self.substitutions += min(a1 - a0, b1 - b0)
                    self.deletions += max(0, (a1 - a0) - (b1 - b0))
                    self.insertions += max(0, (b1 - b0) - (a1 - a0))
                elif tag == "delete":
                    self.deletions += a1 - a0
                elif tag == "insert":
                    self.insertions += b1 - b0
                self.differences.append((" ".join(w for w, _ in reference[a0:a1]), " ".join(w["norm"] for w in heard[b0:b1])))
            pointer += last_matched + 1
            reference_offset += len(reference)
        self.wer = (self.substitutions + self.deletions + self.insertions) / max(1, len(self.reference))
        # 每一句對到的字（收到的第幾個字）
        self.sentence_words = {}
        for ref_index, word_index in self.aligned.items():
            self.sentence_words.setdefault(self.reference[ref_index][1], []).append(word_index)

        # 收到的每個字是什麼時候說出來的（只有對得上參考稿、而且參考稿有逐字時間時才知道）
        self.spoken = {}
        if self.reference_times:
            for ref_index, word_index in self.aligned.items():
                self.spoken[word_index] = self.reference_times[ref_index]

        # --- 純轉錄連線才有的：用戶端的 commit 與每一段的完成事件 ---
        self.commits = [e for e in self.events if e.get("client") == "commit" and "rx_ms" in e]
        self.completed = {}  # item -> {"rx":…, "text":…}
        for e in self.events:
            event = e.get("event", {})
            if event.get("type") == COMPLETED_TYPE and "rx_ms" in e:
                self.completed[event.get("item_id")] = {"rx": e["rx_ms"] / 1000, "text": event.get("transcript", ""), "usage": event.get("usage")}
        self.committed_order = [(e["rx_ms"] / 1000, e["event"].get("item_id")) for e in self.events
                                if e.get("event", {}).get("type") == "input_audio_buffer.committed" and "rx_ms" in e]

    def spoken_span(self, start, end):
        """字元範圍 [start, end) 裡的字是什麼時候說的：回傳（第一個字開始、最後一個字結束、對得上的字數）。"""
        times = [self.spoken[i] for i, w in enumerate(self.words) if start <= w["start"] < end and i in self.spoken]
        if not times:
            return None
        return min(t[0] for t in times), max(t[1] for t in times), len(times)

    def terminator_time(self, word_index):
        """這個字後面、下一個字之前出現的句號（. ? !）的到達時間；沒有就回傳 None。"""
        start = self.words[word_index]["end"]
        stop = self.words[word_index + 1]["start"] if word_index + 1 < len(self.words) else len(self.stream)
        for position in range(start, stop):
            if self.stream[position] in TERMINATORS:
                return self.chars[position][1]
        return None
