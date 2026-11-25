#!/usr/bin/env python3
"""比較英文辨識：OpenAI 的正式引擎（thunderbench live）與 Apple 的本機辨識（thunderbench local），同一段錄音。（探索用）

用法：asr-compare.py <參考稿.json> <名稱>=<事件.jsonl> [<名稱>=<事件.jsonl> ...]
      名稱以 openai 開頭的是 live 的事件，其他的是 local 的事件；local 的名稱可以加 @顯示方式（見 local_run），例如 fast@agree2。

參考稿：ami-reference.py 的輸出（人工逐字稿，每個字的時間；標點另外標記）。指標：
- 錯字率：兩邊用同一套正規化（小寫、去掉標點、um／uh／hmm 這類口頭聲音不算、數字轉成英文字、ok 當成 okay）後逐字比對。
  多人同時說話的地方，參考稿依開始時間交錯排列，兩邊都會因此多算一些錯，只能互相比較。
- 出現的延遲：參考稿裡一個字說完，到畫面上出現這個位置的字（依畫面上的字數算，暫時的結果也算）。
  模擬時每包音訊在它開始的時間就送出，App 要錄完那一包才送得出去，所以加上一包的長度（live 0.2 秒、local 0.1 秒）。
- 確定的延遲：說完到這個字所在的那一段確定（live 的段結束、local 的確定結果）；翻譯要等確定才送。
- 改寫：英文出現之後又被換掉的字，佔最後字數的比例。
- 句子的邊界：參考稿的句號、問號、驚嘆號，和辨識結果有沒有落在同一個字後面（精確率、召回率）。整句翻譯靠它判斷一句說完。
報告只寫統計數字，不印任何文字內容。
"""
import json
import re
import statistics
import sys

FILLERS = {"um", "umm", "uh", "uhm", "hmm", "hm", "mm", "mmm", "mhm"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + number_words(n % 100))
    if n < 1_000_000:
        return number_words(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + number_words(n % 1000))
    return str(n)


def normalize(text):
    """一段文字 → 正規化之後的字（list）。"""
    text = text.lower().replace("’", "'").replace("‘", "'").replace("%", " percent").replace("&", " and ")
    text = re.sub(r"(\d),(\d)", r"\1\2", text).replace("-", " ")
    words = []
    for token in re.findall(r"[a-z0-9']+", text):
        token = token.strip("'")
        if not token:
            continue
        if token.isdigit():
            words += number_words(int(token)).split()
            continue
        if token == "ok":
            token = "okay"
        if token not in FILLERS:
            words.append(token)
    return words


def tokens_with_sentence_ends(text):
    """一段辨識結果 → (字, 這個字後面是不是一句的結尾) 的 list。"""
    result = []
    for raw in text.split():
        words = normalize(raw)
        if not words:
            continue
        ends = bool(re.search(r"[.?!][\"')\]]*$", raw))
        result += [(word, False) for word in words[:-1]] + [(words[-1], ends)]
    return result


def align(reference, hypothesis):
    """逐字對齊（編輯距離）。回傳 (替換, 刪除, 插入, [(參考的位置, 辨識的位置)] 對到的字)。"""
    n, m = len(reference), len(hypothesis)
    previous = list(range(m + 1))
    moves = [bytearray(m + 1) for _ in range(n + 1)]  # 0 對角、1 刪除（參考多）、2 插入（辨識多）
    for j in range(1, m + 1):
        moves[0][j] = 2
    for i in range(1, n + 1):
        current = [i] + [0] * m
        moves[i][0] = 1
        word = reference[i - 1]
        for j in range(1, m + 1):
            diagonal = previous[j - 1] + (word != hypothesis[j - 1])
            delete = previous[j] + 1
            insert = current[j - 1] + 1
            if diagonal <= delete and diagonal <= insert:
                current[j], moves[i][j] = diagonal, 0
            elif delete <= insert:
                current[j], moves[i][j] = delete, 1
            else:
                current[j], moves[i][j] = insert, 2
        previous = current
    substitutions = deletions = insertions = 0
    pairs = []
    i, j = n, m
    while i > 0 or j > 0:
        move = moves[i][j]
        if move == 0:
            if reference[i - 1] != hypothesis[j - 1]:
                substitutions += 1
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif move == 1:
            deletions += 1
            i -= 1
        else:
            insertions += 1
            j -= 1
    pairs.reverse()
    return substitutions, deletions, insertions, pairs


def load_reference(path):
    data = json.load(open(path, encoding="utf-8"))
    words, times, ends = [], [], []
    for item in data["words"]:
        if item["punc"]:
            if item["w"] in ".?!" and ends:
                ends[-1] = True
            continue
        for word in normalize(item["w"]):
            words.append(word)
            times.append(item["end"])
            ends.append(False)
    return data, words, times, ends


def read_events(path):
    return [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]


class Display:
    """畫面上的英文：每次更新記下字數，並累計被換掉的字（和上一次比，共同開頭之後的字）。同一個時間點的事件合成一次更新。"""

    def __init__(self):
        self.shown, self.erased, self.timeline = [], 0, []
        # 被換掉的字發生在哪一種更新：final（確定的那一刻）或其他（暫時結果、計時器、live 的增量與段結束）
        self.erased_at_final = 0
        self.pending, self.pending_final = None, False

    def update(self, t, words, final=False):
        if self.timeline and self.timeline[-1][0] == t:
            self.timeline.pop()
            final = final or self.pending_final
        else:
            self.commit()
        self.pending, self.pending_final = words, final
        self.timeline.append((t, len(words)))

    def commit(self):
        words = self.pending
        if words is None:
            return
        # 前面的字幾乎不會變：只比最後 300 個字附近，成本不隨場次變長
        index = max(0, min(len(self.shown), len(words)) - 300)
        while index < min(len(self.shown), len(words)) and self.shown[index] == words[index]:
            index += 1
        self.erased += len(self.shown) - index
        if self.pending_final:
            self.erased_at_final += len(self.shown) - index
        self.shown, self.pending, self.pending_final = words, None, False


def openai_run(events):
    """live 的事件 → 最後的字（附句子的結尾）、每個字確定的時間、畫面上字數的時間軸、被換掉的字數。

    照 App 的字幕資料（CaptionBoard）重建畫面：確定的段依段號排列，後面接正在說的那一段；
    收到任何一段的結束，正在說的那一行就清空（晚到的標點只在下一段還沒有內容時送；晚到的尾巴原本就在正在說的那一行）。
    """
    lines, words, ended_at, display = {}, {}, {}, Display()
    live_segment, live_text = None, ""
    for event in events:
        kind, segment = event.get("kind"), event.get("segment")
        if segment is None or kind not in ("source_delta", "source_end"):
            continue
        if kind == "source_delta":
            if segment != live_segment:
                live_segment, live_text = segment, ""
            live_text += event["text"]
        else:
            lines[segment], words[segment] = event["text"], normalize(event["text"])
            ended_at.setdefault(segment, event["t"])
            live_segment, live_text = None, ""
        display.update(event["t"], [word for s in sorted(words) for word in words[s]] + normalize(live_text))
    display.commit()
    tokens, settled = [], []
    for segment in sorted(lines):
        pieces = tokens_with_sentence_ends(lines[segment])
        tokens += pieces
        settled += [ended_at[segment]] * len(pieces)
    return tokens, settled, display.timeline, display.erased


def common_prefix(hypotheses):
    """幾份結果共同的開頭（字的 list）。"""
    if not hypotheses:
        return []
    first, count = hypotheses[0], min(len(h) for h in hypotheses)
    index = 0
    while index < count and all(h[index] == first[index] for h in hypotheses[1:]):
        index += 1
    return first[:index]


def matched_prefix(final, words):
    """`words` 的開頭對到確定的文字 `final` 到第幾個字為止（逐字對齊，`words` 後面多出來的字不算錯）。

    確定的那一刻，暫時結果裡已經被確定的部分換掉，後面的字（超過確定範圍的）要留在畫面上。
    Apple 的暫時結果沒有逐字的時間，所以用對齊找出切開的位置。
    """
    n, m = len(final), len(words)
    previous = list(range(m + 1))
    for i in range(1, n + 1):
        current = [i] + [0] * m
        for j in range(1, m + 1):
            current[j] = min(previous[j - 1] + (final[i - 1] != words[j - 1]), previous[j] + 1, current[j - 1] + 1)
        previous = current
    return min(range(m + 1), key=lambda j: (previous[j], -j))


def local_run(events, policy="raw"):
    """local 的事件 → 最後的字（附句子的結尾）、每個字確定的時間、畫面上字數的時間軸、被換掉的字數。

    確定的結果照原樣顯示；還沒確定的部分（暫時的結果）照 `policy` 決定顯示多少：
    - none：只顯示確定的結果。
    - raw：整段顯示（Apple 給什麼就顯示什麼）。
    - mask<k>：不顯示最後 k 個字。
    - agree<n>：連續 n 次結果都一樣的開頭才顯示。
    - hold<秒>：一個字（連同前面的字）出現之後這麼久都沒變才顯示；用計時器，不必等下一個結果。
    - freeze<n>：照 agree<n> 加字，顯示過的字不再收回；這一段確定時，有差異才一次換掉。
    """
    name = re.match(r"[a-z]+", policy).group()
    amount = float(policy[len(name):] or 0)
    finals, settled_words, display = [], [], Display()
    hypothesis, since, history, committed = [], [], [], []

    def shown(now):
        if name == "none":
            return []
        if name == "raw":
            return hypothesis
        if name == "mask":
            return hypothesis[:max(0, len(hypothesis) - int(amount))]
        if name == "agree":
            return common_prefix(history[-int(amount):]) if len(history) >= int(amount) else []
        if name == "hold":
            index = 0
            while index < len(hypothesis) and since[index] + amount <= now + 1e-9:
                index += 1
            return hypothesis[:index]
        if name == "freeze":
            return committed
        sys.exit(f"不認識的顯示方式：{policy}")

    items = [event for event in events if event.get("kind") in ("volatile", "final")]
    for position, event in enumerate(items):
        now, words = event["t"], normalize(event["text"])
        if event["kind"] == "volatile":
            same = 0
            while same < min(len(hypothesis), len(words)) and hypothesis[same] == words[same]:
                same += 1
            since = since[:same] + [now] * (len(words) - same)
            hypothesis = words
            history = (history + [words])[-5:]
            if name == "freeze" and len(history) >= int(amount):
                agreed = common_prefix(history[-int(amount):])
                if len(agreed) > len(committed) and agreed[:len(committed)] == committed:
                    committed = agreed
        else:
            finals.append(event)
            settled_words += words
            cut = matched_prefix(words, hypothesis)
            hypothesis, since = hypothesis[cut:], since[cut:]
            committed = committed[matched_prefix(words, committed):]
            history = [hypothesis]
        display.update(now, settled_words + shown(now), final=event["kind"] == "final")
        if name == "hold":
            # 下一個結果來之前，計時到了的字先出現
            following = items[position + 1]["t"] if position + 1 < len(items) else float("inf")
            current = now
            while True:
                count = len(shown(current))
                if count >= len(hypothesis):
                    break
                due = since[count] + amount
                if due >= following:
                    break
                current = max(current, due)
                display.update(current, settled_words + shown(current))
    display.commit()
    tokens, settled = [], []
    for event in sorted(finals, key=lambda item: item["start"]):
        pieces = tokens_with_sentence_ends(event["text"])
        tokens += pieces
        settled += [event["t"]] * len(pieces)
    return tokens, settled, display.timeline, display.erased


def first_shown(timeline, count):
    """畫面上第 i 個字第一次出現的時間（畫面上的字數第一次超過 i）。"""
    shown = [None] * count
    best = 0
    for t, number in timeline:
        while best < min(number, count):
            shown[best] = t
            best += 1
    return shown


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int(fraction * len(values)))] if values else float("nan")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    data, reference, ref_times, ref_ends = load_reference(sys.argv[1])
    print(f"{data['meeting']}（{data['duration'] / 60:.0f} 分鐘，參考稿 {len(reference)} 個字、{sum(ref_ends)} 個句子的結尾）")
    header = "| | 錯字率 | 替換／刪除／插入 | 出現的延遲（中位數／P90） | 確定的延遲（中位數／P90） | 改寫 | 句子邊界（精確／召回） |"
    print(header)
    print("|" + "---|" * 7)
    for argument in sys.argv[2:]:
        name, path = argument.split("=", 1)
        events = read_events(path)
        is_openai = name.startswith("openai")
        policy = name.split("@", 1)[1] if "@" in name else "raw"
        tokens, settled, timeline, erased = openai_run(events) if is_openai else local_run(events, policy)
        chunk = 0.2 if is_openai else 0.1
        words = [word for word, _ in tokens]
        substitutions, deletions, insertions, pairs = align(reference, words)
        shown = first_shown(timeline, len(words))
        shown_lags = [shown[j] + chunk - ref_times[i] for i, j in pairs if shown[j] is not None]
        settled_lags = [settled[j] + chunk - ref_times[i] for i, j in pairs]
        both = sum(1 for i, j in pairs if ref_ends[i] and tokens[j][1])
        hypothesis_ends = sum(1 for i, j in pairs if tokens[j][1])
        reference_ends = sum(1 for i, j in pairs if ref_ends[i])
        print(
            f"| {name} | {(substitutions + deletions + insertions) / len(reference) * 100:.1f}% "
            f"| {substitutions}／{deletions}／{insertions} "
            f"| {statistics.median(shown_lags):.2f}／{percentile(shown_lags, 0.9):.2f} 秒 "
            f"| {statistics.median(settled_lags):.2f}／{percentile(settled_lags, 0.9):.2f} 秒 "
            f"| {erased / max(1, len(words)) * 100:.0f}% "
            f"| {both / max(1, hypothesis_ends) * 100:.0f}%／{both / max(1, reference_ends) * 100:.0f}% |")


if __name__ == "__main__":
    main()
