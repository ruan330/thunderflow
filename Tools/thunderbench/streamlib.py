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

        # --- 對齊 ---
        matcher = difflib.SequenceMatcher(a=[w for w, _ in self.reference], b=[w["norm"] for w in self.words], autojunk=False)
        self.aligned = {}  # 稿子的第幾個字 -> 收到的第幾個字
        self.substitutions = self.deletions = self.insertions = 0
        self.differences = []
        for tag, a0, a1, b0, b1 in matcher.get_opcodes():
            if tag == "equal":
                for k in range(a1 - a0):
                    self.aligned[a0 + k] = b0 + k
                continue
            if tag == "replace":
                self.substitutions += min(a1 - a0, b1 - b0)
                self.deletions += max(0, (a1 - a0) - (b1 - b0))
                self.insertions += max(0, (b1 - b0) - (a1 - a0))
            elif tag == "delete":
                self.deletions += a1 - a0
            elif tag == "insert":
                self.insertions += b1 - b0
            self.differences.append((" ".join(w for w, _ in self.reference[a0:a1]), " ".join(w["norm"] for w in self.words[b0:b1])))
        self.wer = (self.substitutions + self.deletions + self.insertions) / max(1, len(self.reference))
        # 每一句對到的字（收到的第幾個字）
        self.sentence_words = {}
        for ref_index, word_index in self.aligned.items():
            self.sentence_words.setdefault(self.reference[ref_index][1], []).append(word_index)

        # --- 純轉錄連線才有的：用戶端的 commit 與每一段的完成事件 ---
        self.commits = [e for e in self.events if e.get("client") == "commit" and "rx_ms" in e]
        self.completed = {}  # item -> {"rx":…, "text":…}
        for e in self.events:
            event = e.get("event", {})
            if event.get("type") == COMPLETED_TYPE and "rx_ms" in e:
                self.completed[event.get("item_id")] = {"rx": e["rx_ms"] / 1000, "text": event.get("transcript", ""), "usage": event.get("usage")}
        self.committed_order = [(e["rx_ms"] / 1000, e["event"].get("item_id")) for e in self.events
                                if e.get("event", {}).get("type") == "input_audio_buffer.committed" and "rx_ms" in e]

    def terminator_time(self, word_index):
        """這個字後面、下一個字之前出現的句號（. ? !）的到達時間；沒有就回傳 None。"""
        start = self.words[word_index]["end"]
        stop = self.words[word_index + 1]["start"] if word_index + 1 < len(self.words) else len(self.stream)
        for position in range(start, stop):
            if self.stream[position] in TERMINATORS:
                return self.chars[position][1]
        return None
