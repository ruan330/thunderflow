#!/usr/bin/env python3
"""把 translate 或 transcribe 實驗錄下的事件整理成可以提交的測試資料。

- 每行保留：收到的時間（rx_ms）、當時已送出的音訊（sent_ms）、事件本身。
- transcribe 的紀錄還有用戶端自己的動作（例如送出 commit），原樣保留，重播時才知道何時 commit。
- 譯文語音的內容本來就沒有存（只有大小）。
- 工作階段的 id 與錯誤訊息裡被遮罩的金鑰一律改成固定字樣。

用法：make-fixtures.py <實驗資料夾> <輸出檔.jsonl>
"""
import json
import re
import sys

source, destination = sys.argv[1], sys.argv[2]
KEY = re.compile(r"sk-[A-Za-z0-9_\-\*]+")
count = 0
with open(f"{source}/events.jsonl", encoding="utf-8") as lines, open(destination, "w", encoding="utf-8") as out:
    for line in lines:
        record = json.loads(line)
        if "client" in record:
            keep = ("rx_ms", "sent_ms", "client", "reason", "turn_seconds", "index")
        else:
            keep = ("rx_ms", "sent_ms", "event")
            session = record["event"].get("session")
            if isinstance(session, dict) and "id" in session:
                session["id"] = "sess_REDACTED"
        text = json.dumps({k: record[k] for k in keep if k in record},
                          ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        out.write(KEY.sub("sk-REDACTED", text) + "\n")
        count += 1
print(f"{destination}: {count} 個事件")
