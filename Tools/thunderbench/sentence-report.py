#!/usr/bin/env python3
"""把 sentence-retranslate.py 的 result.json 排成一頁 HTML：上面是數字，下面是每一句的三種中文並排。

用法：sentence-report.py <result.json> <輸出.html>
"""
import html
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))
out = sys.argv[2]
e = html.escape

rows = []
for i, row in enumerate(result["rows"], 1):
    split = len(row["segments"]) > 1
    english = " <span class=cut>｜</span> ".join(e(x) for x in row["en"])
    now = "<span class=cut>｜</span>".join(e(x) for x in row["now"])
    rows.append(
        f'<tr class="{"split" if split else "single"}"><td class=n>{i}</td><td class=en>{english}</td>'
        f'<td>{now}</td><td>{e(row["a"])}</td><td>{e(row["whole"])}</td></tr>')

metrics = result["metrics"]
metric_rows = "".join(
    f"<tr><td>{e(name)}</td><td>{m['displayed_changed'] * 100:.0f}%</td><td>{m['sentences_rewritten'] * 100:.0f}%</td>"
    f"<td>{m['white_changed'] * 100:.0f}%</td><td>{m['first_median']:.1f} 秒</td>"
    f"<td>{m['white_median']:.1f}／{m['white_p95']:.1f} 秒</td></tr>"
    for name, m in metrics.items())

page = f"""<!doctype html>
<html lang="zh-Hant-TW"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>字幕翻譯實驗</title>
<style>
:root {{ --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --cut:#c0392b; --band:#f5f5f7; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#111; --fg:#f2f2f2; --muted:#9a9a9f; --line:#2c2c2e; --cut:#ff7b6b; --band:#1c1c1e; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.6 -apple-system, "PingFang TC", sans-serif; margin:0; padding:24px 16px 64px; }}
main {{ max-width:1400px; margin:0 auto; }}
h1 {{ font-size:22px; margin:0 0 4px; }} h2 {{ font-size:17px; margin:32px 0 8px; }}
p, li {{ color:var(--muted); }} .note {{ font-size:13px; }}
table {{ border-collapse:collapse; width:100%; }}
th, td {{ border-bottom:1px solid var(--line); padding:8px 10px; vertical-align:top; text-align:left; }}
th {{ font-size:13px; color:var(--muted); font-weight:600; position:sticky; top:0; background:var(--bg); }}
td.n {{ color:var(--muted); font-size:12px; width:28px; }}
td.en {{ color:var(--muted); font-size:13px; width:28%; }}
.cut {{ color:var(--cut); font-weight:700; }}
tr.split td {{ background:var(--band); }}
.metrics td, .metrics th {{ white-space:nowrap; }}
.wrap {{ overflow-x:auto; }}
label {{ display:inline-block; margin:8px 0 12px; cursor:pointer; }}
body.only-split tr.single {{ display:none; }}
</style></head><body><main>
<h1>字幕翻譯實驗：逐段翻 vs 整句重翻</h1>
<p>材料：37C3「NEW IMPORTANT INSTRUCTIONS」（Johann Rehberger，CC BY 4.0，<a href="https://media.ccc.de/v/37c3-12292-new_important_instructions">media.ccc.de</a>）第 3–13 分鐘，真人現場演講。
英文是 ThunderFlow 的即時引擎聽到的（設定和 App 一樣），三種中文用的是同一份英文、同一個模型（{e(result["model"])}，reasoning {e(result["effort"])}），差別只在怎麼翻。</p>
<p>{result["segments"]} 段、{result["sentences"]} 句，其中 <b>{result["split_sentences"]} 句被切成 2 段以上</b>（灰底）。
A 的整句翻譯：中位數 {result["a_latency_median"]:.2f} 秒、P95 {result["a_latency_p95"]:.2f} 秒。</p>

<h2>畫面上的字改了多少（「字一直變」）</h2>
<div class=wrap><table class=metrics>
<tr><th>顯示方式</th><th>顯示過的字<br>後來被改掉</th><th>有被改寫的句子</th><th>白字（定稿）<br>被改掉</th><th>第一個中文字<br>（開口後，中位數）</th><th>白字到齊<br>（說完後，中位數／P95）</th></tr>
{metric_rows}
</table></div>
<ul class=note>
<li>D0 是現在的 App：暫定譯文 → 每段的定稿（白字）。D0b 是現在的 App 關掉「顯示暫定譯文」。</li>
<li>D1–D3 是 A：一句說完之前，段的中文都是灰字；整句譯文回來後換成白字，之後不再變。一句的最後一段不另外翻（整句譯文就是它的定稿）。差別在灰字怎麼出：D1 和現在一樣，D2 不顯示暫定譯文，D3 只顯示連續兩版相同的開頭。</li>
<li>「被改掉」= 已經顯示在畫面上、之後被換掉的字。整句譯文取代段的譯文也算一次改寫。</li>
</ul>

<h2>每一句的中文</h2>
<label><input type=checkbox id=only> 只看被切成 2 段以上的句子</label>
<div class=wrap><table>
<tr><th>#</th><th>英文（<span class=cut>｜</span> 是切段的位置）</th><th>現在：逐段翻</th><th>A：一句說完整句重翻</th><th>整場一次翻（DeepSRT 的做法）</th></tr>
{''.join(rows)}
</table></div>
</main>
<script>
document.getElementById('only').addEventListener('change', function () {{
  document.body.classList.toggle('only-split', this.checked);
}});
</script>
</body></html>
"""
open(out, "w", encoding="utf-8").write(page)
print(out)
