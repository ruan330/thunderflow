#!/usr/bin/env python3
"""從測試原始碼產生 TESTS.md：每個測試組與測試的名稱。

用法：Scripts/list-tests.py          重新產生 TESTS.md
      Scripts/list-tests.py --check  只檢查 TESTS.md 是不是最新的（給 CI 用）
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "Packages" / "ThunderKit" / "Tests"
OUTPUT = ROOT / "TESTS.md"

DECLARATION = re.compile(r'@(Suite|Test)\(\s*"((?:[^"\\]|\\.)*)"(.*?)\)\s*\n\s*(?:struct|func)', re.S)


def condition(traits: str) -> str:
    if "isOptimizedBuild" in traits:
        return "（只在 release 模式執行：`make test-perf`）"
    if "THUNDER_SOAK" in traits:
        return "（要明確要求才執行：`make test-soak`）"
    return ""


def cases(traits: str) -> str:
    match = re.search(r"arguments:\s*\[(.*?)\]", traits, re.S)
    if match:
        return f"（{len([a for a in match.group(1).split(',') if a.strip()])} 組參數）"
    if "arguments:" in traits:
        return "（多組參數）"
    return ""


def render() -> str:
    lines = [
        "# 測試清單",
        "",
        "> 由 `Scripts/list-tests.py` 從測試原始碼產生，請勿手動編輯。",
        "> 測試就是規格：每一行是一個必須成立的行為。流程與分層見 [DESIGN.md](DESIGN.md) 第 9 節。",
        "",
    ]
    total = 0
    for target in sorted(p for p in TESTS.iterdir() if p.is_dir()):
        section = [f"## {target.name}", ""]
        count = 0
        for source in sorted(target.glob("*.swift")):
            for kind, name, traits in DECLARATION.findall(source.read_text(encoding="utf-8")):
                if kind == "Suite":
                    section += ["", f"### {name}{condition(traits)}", ""]
                else:
                    section.append(f"- {name}{cases(traits)}")
                    count += 1
        if count:
            section[0] = f"## {target.name}（{count} 個測試）"
            lines += section + [""]
            total += count
    lines.insert(4, f"> 目前共 {total} 個測試。")
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).rstrip() + "\n"


def main() -> int:
    text = render()
    if "--check" in sys.argv:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != text:
            print("TESTS.md 不是最新的，請執行 Scripts/list-tests.py", file=sys.stderr)
            return 1
        print("ok：TESTS.md 是最新的")
        return 0
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"已更新 {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
