// v4.0.22 候选池⑪ App 侧「扫账单」纯逻辑真值表 —— Linux 本地预检用，纯 Foundation，无 UI 依赖
//
// 编译运行（在仓库根目录，权威入口是 check_swift.sh 的第 60 段）：
//   ./check_swift.sh
// 等价于：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_bill \
//       scripts/ql_bill/truth_table_bill.swift qingliao/Core/BillScanKit.swift
//
// 本表钉死的口径（都是「漏一条就出错账」的地方）：
//   · amount 缺失 → 草稿必须出但金额为 nil（**不许拿 0 冒充**：账本里 0 是真数字）
//   · amount 与 item 双空（后端只认「不是全空」，只有日期也返回 ok:true）→ 当失败，别弹空确认页
//   · category 不在后端白名单 → 收敛成「其他」，且白名单与后端 BILL_CATEGORIES 逐字一致
//   · 浮点尾巴（21.400000000000002）→ 进账本前四舍五入到分
//   · ok 判成败（HTTP 一律 200）→ 看状态码会把明确失败当成功
//   反例占本表约三分之一。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

@main
struct BillTruthTable {

    static func draft(_ json: [String: Any]) -> BillDraft? { BillScanKit.draft(from: json) }

    static func runAllTests() {
        // ── 1. base64 去 data: 前缀（后端只要裸 base64） ──
        positives += 1
        check("base64：剥掉 data:image/jpeg;base64, 前缀",
              BillScanKit.base64(from: "data:image/jpeg;base64,QUJD") == "QUJD")
        positives += 1
        check("base64：裸串（无逗号）返回 nil 而不是整串当 base64",
              BillScanKit.base64(from: "QUJD") == nil)
        negatives += 1
        check("反例：空 payload（只有前缀和逗号）返回 nil，别让后端拿空图去识别",
              BillScanKit.base64(from: "data:image/jpeg;base64,") == nil)

        // ── 2. 正常账单 ──
        let normal: [String: Any] = ["ok": true, "amount": 21.4, "date": "2026-10-01",
                                     "category": "购物", "item": "便利店购物",
                                     "confidence": 0.9, "source": "cloud-vision"]
        if let d = draft(normal) {
            positives += 1
            check("正常：金额读出", d.amount.map { approx($0, 21.4) } ?? false)
            positives += 1
            check("正常：分类原样保留", d.category == "购物")
            positives += 1
            check("正常：标题用摘要", BillScanKit.title(d) == "便利店购物")
            positives += 1
            check("正常：备注带来源与消费日期", BillScanKit.note(d) == "扫账单 · 2026-10-01")
            positives += 1
            check("正常：把握大不提示核对", BillScanKit.needsReview(d) == false)
        } else {
            negatives += 1
            check("正常：完整账单必须解析成功", false)
        }

        // ── 3. 金额缺失（要出草稿，但金额为 nil）──
        let noAmount: [String: Any] = ["ok": true, "amount": NSNull(), "date": "",
                                       "category": "餐饮", "item": "面馆", "confidence": 0.4]
        if let d = draft(noAmount) {
            positives += 1
            check("金额缺失：草稿仍出（让用户手填），金额为 nil", d.amount == nil)
            positives += 1
            check("金额缺失：标题仍可用", BillScanKit.title(d) == "面馆")
            positives += 1
            check("金额缺失：confidence 低 → 提示核对", BillScanKit.needsReview(d))
            positives += 1
            check("金额缺失：日期为空时备注退化", BillScanKit.note(d) == "扫账单")
        } else {
            negatives += 1
            check("金额缺失但有摘要：不该判失败", false)
        }

        // ── 4. 只剩日期（后端也 ok:true，但没法入账）──
        negatives += 1
        check("反例：只有日期、没金额没摘要 → 判失败，不弹空确认页",
              draft(["ok": true, "amount": NSNull(), "date": "2026-10-01",
                     "category": "其他", "item": "", "confidence": 0.2]) == nil)

        // ── 5. 摘要为空 → 标题回退分类名（空标题 = addDetailed 静默拒收）──
        if let d = draft(["ok": true, "amount": 8.0, "date": "", "category": "交通",
                          "item": "   ", "confidence": 0.8]) {
            positives += 1
            check("摘要空白（只有空格）：标题回退分类名，绝不是空串",
                  BillScanKit.title(d) == "交通" && !BillScanKit.title(d).isEmpty)
        } else {
            negatives += 1
            check("摘要空白但有金额：不该判失败", false)
        }

        // ── 6. 分类白名单 ──
        // 逐字比对 8 个值（不是只数个数）：改一个字（如「居住」→「教育」）后端 _norm_bill 就会把它收敛成
        // 「其他」，而 App 的分类胶囊还显示「教育」→ 两头分叉。真源 = 后端 intent_api.py 的
        // `BILL_CATEGORIES = ("餐饮", "购物", "交通", "医疗", "娱乐", "居住", "通讯", "其他")`（顺序也一致）。
        positives += 1
        check("分类白名单与后端 BILL_CATEGORIES 逐字一致（8 类，「其他」在末位）",
              BillScanKit.categories == ["餐饮", "购物", "交通", "医疗", "娱乐", "居住", "通讯", "其他"])
        if let d = draft(["ok": true, "amount": 5.0, "date": "", "category": "宠物医疗",
                          "item": "猫粮", "confidence": 0.7]) {
            positives += 1
            check("分类不在白名单 → 收敛成「其他」（不让 App 自造分类）", d.category == "其他")
        } else {
            negatives += 1
            check("分类越界但有金额与摘要：不该判失败", false)
        }

        // ── 7. 浮点尾巴 ──
        positives += 1
        check("浮点：21.400000000000002 → 21.4（四舍五入到分）",
              approx(BillScanKit.money(21.400000000000002), 21.4))
        positives += 1
        check("浮点：0.005 进位到 0.01（别把分位抹掉）",
              approx(BillScanKit.money(0.005), 0.01))
        if let d = draft(["ok": true, "amount": 21.400000000000002, "date": "",
                          "category": "购物", "item": "超市", "confidence": 0.9]) {
            positives += 1
            check("浮点：草稿里的金额已收敛（不是原始尾巴）",
                  d.amount.map { approx($0, 21.4) } ?? false)
        } else {
            negatives += 1
            check("浮点账单：不该判失败", false)
        }

        // ── 8. 失败分支：判成败看 ok，不看 HTTP 状态码 ──
        negatives += 1
        check("反例：ok=false（后端没认出）→ nil，不能当成功弹确认页",
              draft(["ok": false, "error": "图片过大"]) == nil)
        negatives += 1
        check("反例：缺 ok 字段 → nil（不默认成功）",
              draft(["amount": 9.9, "item": "x"]) == nil)
        negatives += 1
        check("反例：空对象 → nil", draft([:]) == nil)
        positives += 1
        check("失败文案：优先用后端 error",
              BillScanKit.failText(from: ["ok": false, "error": "图片过大"]) == "图片过大")
        positives += 1
        check("失败文案：后端没给 error 时给人话（不许空串）",
              !BillScanKit.failText(from: ["ok": false]).isEmpty)
        negatives += 1
        check("反例：ok=false 且 error 为空串 → 仍是人话兜底，不是空字符串",
              !BillScanKit.failText(from: ["ok": false, "error": "  "]).isEmpty)

        // ── 9. 容错：字符串数字 / 缺 confidence / amount=0 ──
        positives += 1
        check("容错：金额以字符串给出（\"21.40\"）也能读",
              draft(["ok": true, "amount": "21.40", "date": "", "category": "餐饮",
                     "item": "早餐", "confidence": 0.9])?.amount.map { approx($0, 21.4) } ?? false)
        if let d = draft(["ok": true, "amount": 3.5, "date": "", "category": "餐饮",
                          "item": "豆浆", "confidence": NSNull()]) {
            positives += 1
            check("容错：confidence 缺失 → 0 → 提示核对（宁可多提示，不谎报有把握）",
                  d.confidence == 0 && BillScanKit.needsReview(d))
        } else {
            negatives += 1
            check("容错：confidence 缺失不该判失败", false)
        }
        positives += 1
        check("容错：amount=0 不当成 nil（0 是数字，拦不拦交给保存按钮判 >0）",
              draft(["ok": true, "amount": 0, "date": "", "category": "其他",
                     "item": "白条", "confidence": 0.9])?.amount != nil)

        // ── 10. 反例补充：字段形态脏的时候不许崩、不许编 ──
        negatives += 1
        check("反例：NSNull 不该变成字符串 \"null\"（text 取空）", BillScanKit.text(NSNull()).isEmpty)
        negatives += 1
        check("反例：非数字字符串金额（\"abc\"）当 nil，不当 0", BillScanKit.number("abc") == nil)
        negatives += 1
        check("反例：无穷大金额当 nil（别把 inf 写进账本）",
              BillScanKit.number(NSNumber(value: Double.infinity)) == nil)
        negatives += 1
        check("反例：ok 为字符串 \"false\" 不算成功",
              draft(["ok": "false", "amount": 9.9, "item": "x"]) == nil)
        negatives += 1
        check("反例：只有分类（金额与摘要全空）→ 判失败，不弹空确认页",
              draft(["ok": true, "amount": NSNull(), "date": "", "category": "餐饮",
                     "item": "", "confidence": 0.9]) == nil)
        negatives += 1
        check("反例：日期字段是数字时不崩（text 取空，不当 \"1\" 展示）",
              BillScanKit.text(NSNumber(value: 1)).isEmpty)
        negatives += 1
        check("反例：空 base64 输入 → nil（别让后端拿空图去识别）",
              BillScanKit.base64(from: "") == nil)
        negatives += 1
        check("反例：分位以下的脏尾巴不透传（0.004999 → 0.00）",
              approx(BillScanKit.money(0.004999), 0.0))

        // ── 11. 源级：入口与状态复位必须都在**代码**里（与 check_swift.sh 的存在性 grep 对拍）──
        // 不用真值表看不到 UI，就靠源级断言兜底；读不到文件时按 0 分记（宁可红，不许假绿）。
        let recSrc = (try? String(contentsOfFile: "qingliao/Features/Life/RecordSection.swift",
                                  encoding: .utf8)) ?? ""
        positives += 1
        check("源级：读得到记录页源码（读不到=护栏空转）", !recSrc.isEmpty)
        positives += 1
        check("源级：扫账单弹窗挂 `.id(billScanSession)`（SwiftUI 复用已呈现视图的 @State → 不换实例=重开带旧图/旧金额）",
              recSrc.contains("BillScanSheet().id(billScanSession)"))
        positives += 1
        check("源级：入口 action 先自增会话号再 present（顺序反了换不出新实例）",
              recSrc.contains("billScanSession += 1") && recSrc.contains("showBillScan = true"))
        // 剥行注释后的「代码形态」断言：注释里写「扫账单」不算入口（否则就是假绿）
        let recCode = recSrc.components(separatedBy: "\n")
            .map { String($0.components(separatedBy: "//")[0]) }
            .joined(separator: "\n")
        positives += 1
        check("源级：剥掉行注释后入口实参仍在（`secondaryAction: (title: \"扫账单\", action:`）",
              recCode.contains("secondaryAction: (title: \"扫账单\", action:"))
        // 手填金额那一路也必须挡 inf / 超限（审查实测：Double(\"inf\") / Double(\"1e400\") 返回 inf 而不是 nil，
        // 只判 > 0 会把 inf 写进账本 → 本月合计与 CSV 全变 inf）。上限对齐后端 _norm_bill（> 1 亿当没认出来）。
        let sheetSrc = (try? String(contentsOfFile: "qingliao/Features/Life/BillScanSheet.swift",
                                    encoding: .utf8)) ?? ""
        positives += 1
        check("源级：读得到扫账单弹窗源码（读不到=护栏空转）", !sheetSrc.isEmpty)
        positives += 1
        check("源级：手填金额挡 isFinite（inf 不许进账本）", sheetSrc.contains("value.isFinite"))
        positives += 1
        check("源级：手填金额上限对齐后端（100_000_000）", sheetSrc.contains("value <= 100_000_000"))
        positives += 1
        check("源级：连点去重命中时不当「新建成功」（读 inserted 标志）",
              sheetSrc.contains("guard added.inserted else"))

        // ── 12. 反例补充：脏值与边界 ──
        negatives += 1
        check("反例：NaN 金额当 nil（与 inf 同源：都是 isFinite 为假）",
              BillScanKit.number(Double.nan) == nil)
        negatives += 1
        check("反例：字符串形态的 inf（\"inf\"/\"1e400\"）也当 nil（String 分支同样要挡 isFinite）",
              BillScanKit.number("inf") == nil && BillScanKit.number("1e400") == nil)
        negatives += 1
        check("反例：只有前缀没有载荷的 base64 → nil（别拿空图去识别）",
              BillScanKit.base64(from: "data:image/jpeg;base64,") == nil)
        negatives += 1
        check("反例：有把握（confidence=1.0）时不提示核对（提示多了=狼来了）",
              draft(["ok": true, "amount": 1.0, "date": "", "category": "其他",
                     "item": "x", "confidence": 1.0]).map { BillScanKit.needsReview($0) } == false)
    }

    static func main() {
        runAllTests()
        let total = positives + negatives
        let ratio = total == 0 ? 0 : Double(negatives) / Double(total)
        check("反例 ≥ 三分之一（正例 \(positives) / 反例 \(negatives) / 占比 \(Int(ratio * 100))%）",
              ratio >= 1.0 / 3.0)
        print(failures == 0 ? "\n🎉 全部通过（0 失败）" : "\n❌ \(failures) 个失败")
        exit(failures == 0 ? 0 : 1)
    }
}
