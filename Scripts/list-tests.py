#!/usr/bin/env python3
"""從測試原始碼產生 TESTS.md：每個測試組與測試的名稱。

用法：Scripts/list-tests.py          重新產生 TESTS.md
      Scripts/list-tests.py --check  只檢查 TESTS.md 是不是最新的（給 CI 用）

兩種用法都先做兩個檢查，沒通過就不寫檔，以非零的狀態結束：
- 解析的自我檢查：一段各種寫法的範例（宣告前面有別的屬性或修飾詞、tuple 與巢狀陣列的參數）要解析正確。
- 列出的測試數要等於原始碼裡 `@Test` 的個數：有測試的寫法沒認出來時，不會默默少算。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "Packages" / "ThunderKit" / "Tests"
OUTPUT = ROOT / "TESTS.md"

DECLARATION = re.compile(r'@(Suite|Test)\(\s*"((?:[^"\\]|\\.)*)"(.*?)\)\s*\n\s*(?:struct|func)', re.S)


def declarations(text: str) -> list[tuple[str, str, str]]:
    """原始碼裡依序出現的測試組與測試：(Suite 或 Test, 名稱, 名稱後面的其餘參數)。"""
    return DECLARATION.findall(text)


def attribute_count(text: str) -> int:
    """原始碼裡 `@Test` 的個數（不算 `//` 註解裡的）。"""
    return len(re.findall(r"@Test\b", re.sub(r"//[^\n]*", "", text)))


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


def line(kind: str, name: str, traits: str) -> str:
    """TESTS.md 裡的一行：測試組是標題，測試是清單的一項。"""
    return f"### {name}{condition(traits)}" if kind == "Suite" else f"- {name}{cases(traits)}"


# 解析的自我檢查：各種寫法的範例，和它應該產生的每一行。
SAMPLE = '''
@Suite("範例", .enabled(if: isOptimizedBuild))
@MainActor
struct Sample {
    @Test("一般的寫法")
    func plain() {}

    @Test("前面有修飾詞", arguments: [1, 2, 3])
    fileprivate func modified(value: Int) {}

    @Test(
        "tuple 的參數，字串裡有逗號與括號",
        arguments: [
            ("a, b", [1, 2]),
            ("(c", []),
        ] as [(String, [Int])])
    @available(macOS 26, *)
    private static func tuples(text: String, values: [Int]) {}

    @Test("巢狀陣列的參數", arguments: [[2], [1, 1]])
    nonisolated func nested(layout: [Int]) {}
}
'''
SAMPLE_LINES = [
    "### 範例（只在 release 模式執行：`make test-perf`）",
    "- 一般的寫法",
    "- 前面有修飾詞（3 組參數）",
    "- tuple 的參數，字串裡有逗號與括號（2 組參數）",
    "- 巢狀陣列的參數（2 組參數）",
]


def self_test() -> list[str]:
    """回傳範例解析不符合的地方；空的就是通過。"""
    found = [line(*declaration) for declaration in declarations(SAMPLE)]
    return [] if found == SAMPLE_LINES else ["應該是：", *SAMPLE_LINES, "實際是：", *found]


def render() -> tuple[str, int, int]:
    """回傳 TESTS.md 的內容、列出的測試數，以及原始碼裡 `@Test` 的個數。"""
    lines = [
        "# 測試清單",
        "",
        "> 由 `Scripts/list-tests.py` 從測試原始碼產生，請勿手動編輯。",
        "> 測試就是規格：每一行是一個必須成立的行為。流程與分層見 [DESIGN.md](DESIGN.md) 第 9 節。",
        "",
    ]
    total = 0
    attributes = 0
    for target in sorted(p for p in TESTS.iterdir() if p.is_dir()):
        section = [f"## {target.name}", ""]
        count = 0
        for source in sorted(target.glob("*.swift")):
            text = source.read_text(encoding="utf-8")
            attributes += attribute_count(text)
            for kind, name, traits in declarations(text):
                if kind == "Suite":
                    section += ["", line(kind, name, traits), ""]
                else:
                    section.append(line(kind, name, traits))
                    count += 1
        if count:
            section[0] = f"## {target.name}（{count} 個測試）"
            lines += section + [""]
            total += count
    lines.insert(4, f"> 目前共 {total} 個測試。")
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).rstrip() + "\n", total, attributes


def main() -> int:
    problems = self_test()
    if problems:
        print("list-tests.py 的解析有誤，自我檢查沒有通過。", *problems, sep="\n  ", file=sys.stderr)
        return 1
    text, total, attributes = render()
    if total != attributes:
        print(f"list-tests.py 只認出 {total} 個測試，但原始碼裡有 {attributes} 個 @Test：有測試的寫法沒有認出來",
              file=sys.stderr)
        return 1
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
