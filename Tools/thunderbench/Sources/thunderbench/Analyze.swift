import Foundation

/// 在台灣繁體中文裡本來就常見、但 ICU 的簡轉繁會改動的字。出現這些字不代表譯文是簡體。
private let sharedCharacters: Set<Character> = [
    "台", "里", "后", "面", "只", "干", "系", "松", "余", "云", "志", "制", "准", "几", "表", "划", "回", "向",
    "才", "丑", "斗", "谷", "姜", "借", "克", "困", "蒙", "秋", "曲", "舍", "于", "并", "布", "采", "沖", "出",
    "党", "淀", "范", "复", "杠", "个", "合", "胡", "伙", "家", "价", "卷", "据", "扣", "累", "了", "霉", "弥",
    "蔑", "辟", "朴", "仆", "千", "签", "纤", "舌", "升", "尸", "术", "涂", "万", "咸", "象", "吁", "须", "熏",
    "叶", "佣", "涌", "游", "郁", "御", "愿", "岳", "症", "征", "致", "种", "周", "朱", "筑", "着", "托", "占",
    "群", "床", "峰", "著", "啟", "線", "為", "裏", "麼", "衆", "牆", "綫", "污", "鉤", "腳", "決", "況", "涼",
    "強", "卻", "眾", "秘", "床", "真", "說", "內", "溫", "產", "稅", "脫", "悅", "閱", "銳", "兌",
]

/// 明確屬於中國大陸用語的詞（台灣不這樣說）。比對前會先把文字轉成繁體字。
private let mainlandTerms: [String: String] = [
    "軟件": "軟體", "硬件": "硬體", "數據": "資料", "視頻": "影片", "網絡": "網路", "服務器": "伺服器",
    "默認": "預設", "信息": "資訊", "內存": "記憶體", "用戶": "使用者", "程序員": "工程師", "屏幕": "螢幕",
    "打印": "列印", "鼠標": "滑鼠", "博客": "部落格", "攝像頭": "攝影機", "激光": "雷射", "質量": "品質",
    "項目": "專案", "接口": "介面", "代碼": "程式碼", "算法": "演算法", "運行": "執行", "訪問": "存取",
    "存儲": "儲存", "配置": "設定", "實例": "執行個體", "響應": "回應", "端口": "連接埠", "帶寬": "頻寬",
    "模塊": "模組", "調用": "呼叫", "字符": "字元", "鏈接": "連結", "登錄": "登入", "賬戶": "帳戶",
    "人工智能": "人工智慧", "機器學習模型訓練": "",
]

func analyze(_ arguments: Arguments) throws {
    guard arguments.positional.count >= 2 else {
        fail("用法：thunderbench analyze <translate 的輸出資料夾> [--terms <terms.json> --name keynote]")
    }
    let directory = URL(fileURLWithPath: arguments.positional[1], isDirectory: true)
    let translation = try String(contentsOf: directory.appendingPathComponent("translation.txt"), encoding: .utf8)
    let source = (try? String(contentsOf: directory.appendingPathComponent("source.txt"), encoding: .utf8)) ?? ""
    var report: [String: Any] = [:]

    // 1. 簡體或繁體
    let han = translation.filter { $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }
    var simplified: [Character: Int] = [:]
    var traditional = 0
    for character in han {
        let text = String(character)
        let toTraditional = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        let toSimplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        if toTraditional != text, !sharedCharacters.contains(character) { simplified[character, default: 0] += 1 }
        if toSimplified != text { traditional += 1 }
    }
    let simplifiedCount = simplified.values.reduce(0, +)
    print("中文字數：\(han.count)　繁體專用字：\(traditional)　簡體專用字：\(simplifiedCount)")
    if !simplified.isEmpty {
        let examples = simplified.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key)×\($0.value)" }
        print("  簡體字：\(examples.joined(separator: " "))")
    }
    let script: String
    switch (simplifiedCount, traditional) {
    case (0, 0): script = "無法判斷（沒有簡繁有別的字）"
    case (0, _): script = "繁體"
    case (_, 0): script = "簡體"
    default: script = simplifiedCount > traditional ? "以簡體為主（混有繁體）" : "以繁體為主（混有簡體）"
    }
    print("  判定：\(script)")
    report["han_characters"] = han.count
    report["traditional_only"] = traditional
    report["simplified_only"] = simplifiedCount
    report["script"] = script

    // 2. 中國大陸用語（先轉成繁體字再比對，簡體輸出也抓得到）
    let asTraditional = translation.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? translation
    var mainlandHits: [String: Int] = [:]
    for (term, _) in mainlandTerms where !term.isEmpty {
        let count = asTraditional.components(separatedBy: term).count - 1
        if count > 0 { mainlandHits[term] = count }
    }
    if mainlandHits.isEmpty {
        print("疑似中國大陸用語：沒有命中")
    } else {
        let listing = mainlandHits.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)（台灣：\(mainlandTerms[$0.key] ?? "")）" }
        print("疑似中國大陸用語（需人工判讀）：\(listing.joined(separator: "、"))")
    }
    report["mainland_terms"] = mainlandHits

    // 3. 術語與數字
    if let termsPath = arguments.options["terms"], let name = arguments.options["name"] {
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: termsPath))) as? [String: Any]
        guard let spec = all?[name] as? [String: Any] else { fail("terms.json 裡沒有「\(name)」") }
        let haystack = asTraditional.lowercased()
        var hit = 0, total = 0
        var missed: [String] = []
        for term in spec["keep"] as? [String] ?? [] {
            total += 1
            if haystack.contains(term.lowercased()) { hit += 1 } else { missed.append("\(term)（應保留英文）") }
        }
        for (english, variants) in spec["zh"] as? [String: [String]] ?? [:] {
            total += 1
            if variants.contains(where: { haystack.contains($0.lowercased()) }) { hit += 1 } else { missed.append("\(english)→\(variants.first ?? "")") }
        }
        var numberHit = 0
        var numberMissed: [String] = []
        let numbers = spec["numbers"] as? [[String]] ?? []
        for variants in numbers {
            if variants.contains(where: { haystack.contains($0.lowercased()) }) { numberHit += 1 } else { numberMissed.append(variants.first ?? "") }
        }
        print("術語：\(hit)／\(total) 正確" + (missed.isEmpty ? "" : "；沒對上：\(missed.sorted().joined(separator: "、"))"))
        print("數字：\(numberHit)／\(numbers.count) 正確" + (numberMissed.isEmpty ? "" : "；沒對上：\(numberMissed.joined(separator: "、"))"))
        report["terms_hit"] = hit
        report["terms_total"] = total
        report["terms_missed"] = missed.sorted()
        report["numbers_hit"] = numberHit
        report["numbers_total"] = numbers.count
        report["numbers_missed"] = numberMissed
    }

    report["source_words"] = source.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: directory.appendingPathComponent("analysis.json"))
}
