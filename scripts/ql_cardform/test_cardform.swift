// CardFormStore 行为测试（#25 可交互卡片 · 提交回执本地持久化）
//
// 编译运行（仓库根目录，工具链见 check_swift.sh；多文件编译只有 main.swift 允许顶层代码 →
// 预检脚本会把它复制成 /tmp 下的 main.swift）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_cardform \
//       qingliao/Core/AgentCardParser.swift qingliao/Core/CardFormStore.swift <本文件>
//
// 覆盖：指纹稳定性与防碰撞 · 提交回读逐字一致（中文/引号/换行）· 同卡重写幂等 · 不同卡隔离 ·
//       容量上限淘汰最旧 · 一键清空（隐私口径）

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

let suiteName = "ql-cardform-test-" + UUID().uuidString
let suite: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
let store = CardFormStore(defaults: suite)

// MARK: - ① 指纹（消息种子 + 标题 + 内容签名）

let sigA = "amount|月投入|number|元|,|3000|1\u{1E}按我填的算：{amount}"
let fp1 = CardFormStore.fingerprint(seed: "msg-1", title: "ROI 试算", signature: sigA)
check("指纹：同种子同内容两次一致", fp1 == CardFormStore.fingerprint(seed: "msg-1", title: "ROI 试算", signature: sigA))
check("指纹：标题变则变", fp1 != CardFormStore.fingerprint(seed: "msg-1", title: "ROI 试算2", signature: sigA))
check("指纹：内容签名变则变（同标题同字段 key、单位不同 → 必须是两张卡）",
      fp1 != CardFormStore.fingerprint(seed: "msg-1", title: "ROI 试算", signature: "amount|月投入|number|万元|,|3000|1\u{1E}按我填的算：{amount}"))
check("指纹：**换消息（跨会话/同会话新一张同题卡）必须是不同卡**",
      fp1 != CardFormStore.fingerprint(seed: "msg-2", title: "ROI 试算", signature: sigA))
check("指纹：种子为空与有种子不同（画廊预览不吃真实卡的回执）",
      CardFormStore.fingerprint(seed: "", title: "T", signature: "s") != CardFormStore.fingerprint(seed: "m", title: "T", signature: "s"))
check("指纹：分隔符防拼接碰撞（AB|C ≠ A|BC）",
      CardFormStore.fingerprint(seed: "t", title: "AB", signature: "C") != CardFormStore.fingerprint(seed: "t", title: "A", signature: "BC"))

// MARK: - ② 空态

check("从未提交 → 读回 nil", store.submission(for: fp1) == nil)

// MARK: - ③ 提交 → 回读（证明 JSON 编码对中文/引号/换行都稳）

let vals = ["amount": "5000", "years": "20", "风格": "激进", "note": "带\"引号\"\n以及换行"]
let sub = CardFormStore.Submission(values: vals, summary: "按我填的算：月投入 5000 元", at: Date(timeIntervalSince1970: 1_760_000_000))
store.record(sub, for: fp1)
let back = store.submission(for: fp1)
check("提交后可回读", back != nil)
check("回读：字段值逐字一致（中文/引号/换行）", back?.values == vals)
check("回读：摘要一致", back?.summary == sub.summary)
check("回读：时刻一致（±1s 容差）", back.map { abs($0.at.timeIntervalSince(sub.at)) < 1 } == true)

// MARK: - ④ 幂等：同一张卡重复提交是覆盖，不是追加

store.record(CardFormStore.Submission(values: ["amount": "1"], summary: "改了"), for: fp1)
check("幂等：同指纹重写 → 只剩最新一条", store.submission(for: fp1)?.summary == "改了")
check("幂等：索引里该指纹只出现一次", store.index().filter { $0 == fp1 }.count == 1)

// MARK: - ⑤ 不同卡隔离

let fp2 = CardFormStore.fingerprint(seed: "msg-9", title: "另一个表", signature: "a|A|text|")
store.record(CardFormStore.Submission(values: ["a": "1"], summary: "B"), for: fp2)
check("不同卡互不串味", store.submission(for: fp1)?.summary == "改了" && store.submission(for: fp2)?.summary == "B")

// MARK: - ⑥ 容量上限：超限淘汰最旧（防 UserDefaults 永久堆积）

for i in 0..<(CardFormStore.maxRecords + 5) {
    let fp = CardFormStore.fingerprint(seed: "msg-\(i)", title: "卡\(i)", signature: "k|K|text|")
    store.record(CardFormStore.Submission(values: ["k": "\(i)"], summary: "s\(i)"), for: fp)
}
check("容量：索引收敛到上限 \(CardFormStore.maxRecords)", store.index().count == CardFormStore.maxRecords)
check("容量：最新写的仍在",
      store.submission(for: CardFormStore.fingerprint(seed: "msg-\(CardFormStore.maxRecords + 4)", title: "卡\(CardFormStore.maxRecords + 4)", signature: "k|K|text|")) != nil)
check("容量：最旧的已被淘汰（读回 nil）",
      store.submission(for: CardFormStore.fingerprint(seed: "msg-0", title: "卡0", signature: "k|K|text|")) == nil)

// MARK: - ⑦ 一键清空（隐私口径）

store.clearAll()
check("清空后索引为空", store.index().isEmpty)
check("清空后旧记录读回 nil", store.submission(for: fp2) == nil)

// MARK: - ⑧ 展示文案

check("展示文案以「已提交」开头", CardFormStore.submittedText(Date()).hasPrefix("已提交"))

// MARK: - ⑨ #17 AI 成品文件段（解析 / 容错丢弃 / kind 归一化 / 纯文本降级）

func parseCard(_ json: String) -> AgentCard? { AgentCard.parse(json: json) }

// 正常：docx + 显式 size（协议原样：path 必填、name/kind/size 可选）
let fJson = #"{"type":"file","title":"周报.docx","file":{"path":"office/周报.docx","name":"周报.docx","kind":"docx","size":36765}}"#
let fc = parseCard(fJson)
check("file 段：卡片解析成功", fc != nil)
check("file 段：path 逐字保留（office/ 别名根不重拼）", fc?.file?.path == "office/周报.docx")
check("file 段：name 逐字保留", fc?.file?.name == "周报.docx")
check("file 段：kind 归一化 docx", fc?.file?.kind == .docx)
check("file 段：size 保留", fc?.file?.size == 36765)
check("file 段：只有文件段的卡不算空卡（isEmpty 计入 file）", fc?.isEmpty == false)

// name 缺省 → path 最后一段；kind 缺省 → 由扩展名推断
let nDef = parseCard(#"{"title":"t","file":{"path":"office/汇总.xlsx"}}"#)
check("file 段：name 缺省取 path 最后一段", nDef?.file?.name == "汇总.xlsx")
check("file 段：kind 缺省由扩展名推断（xlsx）", nDef?.file?.kind == .xlsx)

// 边界（独立审查抓）：path 以 / 结尾 / path 就是别名根本身 → name 不许是空串（否则卡面标题空白）
let slashTail = parseCard(#"{"title":"t","file":{"path":"office/"}}"#)
check("file 段：path 以 / 结尾时 name 取最后非空片段（不出现空标题）", slashTail?.file?.name == "office")
let rootOnly = parseCard(#"{"title":"t","file":{"path":"office"}}"#)
check("file 段：path 就是别名根时 name = office（不空）", rootOnly?.file?.name == "office")
check("file 段：空 name 边界下 plainText 不出「文件：」空行",
      (slashTail?.plainText.contains("文件：office") ?? false))

// size 缺省 → 0（未知，不显示大小）；pdf 扩展名推断
let sDef = parseCard(#"{"title":"t","file":{"path":"office/a.pdf"}}"#)
check("file 段：size 缺省为 0（未知 → 不显示大小）", sDef?.file?.size == 0)
check("file 段：kind 缺省由扩展名推断（pdf）", sDef?.file?.kind == .pdf)

// 图片扩展名 → image；认不出的扩展名 → other
check("file 段：图片扩展名 → image", parseCard(#"{"title":"t","file":{"path":"office/photo.png"}}"#)?.file?.kind == .image)
check("file 段：认不出的扩展名 → other", parseCard(#"{"title":"t","file":{"path":"office/raw.zzz"}}"#)?.file?.kind == .other)

// kind 未知值 → other（**不回落扩展名推断**：白名单外一律 other）
let kUnknown = parseCard(#"{"title":"t","file":{"path":"office/a.pdf","kind":"weird"}}"#)
check("file 段：kind 未知值归一为 other（不回落扩展名推断）", kUnknown?.file?.kind == .other)

// 容错：缺 path / path 为空 / 纯空白 → 整段丢弃（退化成普通只读卡，绝不崩、不出「查看」按钮）
let noPath = parseCard(#"{"type":"file","title":"有标题","file":{"name":"x.docx"}}"#)
check("容错：缺 path → file 段丢弃", noPath != nil && noPath?.file == nil)
check("容错：缺 path 时卡片仍按普通只读卡渲染（不丢整卡）", noPath?.title == "有标题")
check("容错：path 纯空白 → file 段丢弃", parseCard(#"{"type":"file","title":"t","file":{"path":"   "}}"#)?.file == nil)
check("容错：只剩无效 file 段的空卡 → 解析为 nil（不画空白卡）",
      parseCard(#"{"type":"file","file":{"path":""}}"#) == nil)

// 纯文本降级：文件名不能丢（只读/复制/导出/朗读都走 plainText）
check("plainText 含文件名一行", fc?.plainText.contains("文件：周报.docx") == true)

UserDefaults().removePersistentDomain(forName: suiteName)
print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
exit(failures == 0 ? 0 : 1)
