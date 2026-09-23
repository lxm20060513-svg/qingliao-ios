// v3.9.71 意图管道真值表
// 被测逻辑：qingliao/Core/IntentPipeline.swift（生产代码，非镜像副本）
//           + qingliao/Core/QuickReminder.swift（datetime 判定复用它，不另写解析器）
//
// 为什么必须逐条断言：这块一旦误判，用户看到的是「把一串普通数字当成快递单号」、
// 「句子里抄了个日期就弹出加提醒」——假阳性比漏识别更伤（本仓口径）。
// 本机没有 iOS SDK、真机一轮很贵，所以判断逻辑刻意全写成纯 Foundation 纯函数，在这里钉死。
//
// 编译运行（仓库根目录，工具链见 check_swift.sh）：
//   rm -rf /tmp/ql_intent_main && mkdir -p /tmp/ql_intent_main
//   cp scripts/test_intent_pipeline.swift /tmp/ql_intent_main/main.swift
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_intent_pipeline \
//       /tmp/ql_intent_main/main.swift qingliao/Core/IntentPipeline.swift qingliao/Core/QuickReminder.swift
//   /tmp/test_intent_pipeline
//
// ⚠️ 本表只证「识别 + 动作映射 + 字段抽取」；OCR / 端侧语义 / 网络动作只能真机或接口实测。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if ok {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)")
    }
}

/// 固定 now，避免「1 小时后」这类相对时间在不同时刻跑出不同结果
let NOW = ISO8601DateFormatter().date(from: "2026-09-23T20:00:00+08:00")!

func run(_ text: String) -> RecognizedIntent {
    IntentPipeline.classify(text: text, now: NOW)
}

// MARK: - 1. 类型判定：正例

let positives: [(String, IntentKind)] = [
    // express
    ("SF1234567890123", .express),
    ("顺丰快递单号 773012345678901", .express),
    ("快递取件码 YT4512345678901", .express),
    // amount
    ("共 128.50 元", .amount),
    ("发票金额 ¥1,280.00", .amount),
    ("电表读数 1234 度", .amount),
    ("本次用电 56.8 kWh", .amount),
    // datetime
    ("明晚八点提醒我开会", .datetime),
    ("5 分钟后提醒我关火", .datetime),
    ("每天早上 7 点半提醒我吃药", .datetime),
    // link
    ("https://example.com/a/b?x=1", .link),
    ("http://192.168.31.40:8080/api/diag/ping", .link),
    ("www.baidu.com/s?wd=轻聊", .link),
    // contact
    ("13812345678", .contact),
    ("ming@example.com", .contact),
    ("+86 138 1234 5678", .contact),
    // address
    ("上海市浦东新区张江路 100 号", .address),
    ("广东省深圳市南山区科技园南区 8 栋", .address),
]

print("── 1. 正例：类型判定 ──")
for (text, kind) in positives {
    let got = run(text).kind
    check("[\(kind.rawValue)] \(text) → \(got.rawValue)", got == kind)
}

// MARK: - 2. 反例（占 1/3 以上：假阳性比漏识别更伤）

let negatives: [String] = [
    "123456",                       // 纯数字，不是快递号
    "今天天气不错",                  // 普通句子，不该触发 datetime
    "3.5",                          // 光秃秃小数，不是金额
    "2026",                          // 年份，不是金额也不是快递号
    "abcdefg",                       // 无意义串
    "他说他下午可能来",              // 模糊时间，不该弹加提醒
    "￥",                            // 只有符号没有数字
]

print("── 2. 反例：必须落到 text，且只给 问AI/复制 ──")
for text in negatives {
    let r = run(text)
    check("反例 \(text) → text（实得 \(r.kind.rawValue)）", r.kind == .text)
    check("反例 \(text) 置信 <0.5（实得 \(r.confidence)）", r.confidence < 0.5)
    check("反例 \(text) 动作只有 askAI/copy（实得 \(r.actions))",
          Set(r.actions).isSubset(of: [.askAI, .copy]))
}

// MARK: - 3. 动作表映射

print("── 3. 动作表 ──")
func actionsOf(_ text: String) -> Set<IntentAction> { Set(run(text).actions) }

check("快递号 → 含 addTodo", actionsOf("SF1234567890123").contains(.addTodo))
check("快递号 → 不含 storeRecord", !actionsOf("SF1234567890123").contains(.storeRecord))
check("金额 → 含 storeRecord", actionsOf("共 128.50 元").contains(.storeRecord))
check("金额 → 不含 addReminder", !actionsOf("共 128.50 元").contains(.addReminder))
check("日期 → 含 addReminder", actionsOf("明晚八点提醒我开会").contains(.addReminder))
check("日期 → 不含 storeRecord", !actionsOf("明晚八点提醒我开会").contains(.storeRecord))
check("链接 → 含 saveToKB", actionsOf("https://example.com/a/b").contains(.saveToKB))
check("电话 → 含 call", actionsOf("13812345678").contains(.call))
check("邮箱 → 含 mailto", actionsOf("ming@example.com").contains(.mailto))
check("地址 → 含 openMap", actionsOf("上海市浦东新区张江路 100 号").contains(.openMap))
check("每种类型都给 askAI", positives.allSatisfy { actionsOf($0.0).contains(.askAI) })
check("每种类型都给 copy", positives.allSatisfy { actionsOf($0.0).contains(.copy) })

// MARK: - 4. 字段抽取

print("── 4. 字段 ──")
let amt = run("共 128.50 元")
check("金额数值 = 128.5（实得 \(amt.fields["value"] ?? "nil")）",
      Double(amt.fields["value"] ?? "") == 128.5)
check("金额单位 = 元", amt.fields["unit"] == "元")

let ex = run("顺丰快递单号 773012345678901")
check("快递单号抽出来（实得 \(ex.fields["no"] ?? "nil")）",
      ex.fields["no"] == "773012345678901")

let lk = run("https://example.com/a/b?x=1")
check("链接 host = example.com（实得 \(lk.fields["host"] ?? "nil")）",
      lk.fields["host"] == "example.com")

let ct = run("+86 138 1234 5678")
check("手机号归一化（实得 \(ct.fields["value"] ?? "nil")）",
      ct.fields["value"] == "13812345678")

let dt = run("明晚八点提醒我开会")
check("日期 iso 可解析（实得 \(dt.fields["iso"] ?? "nil")）",
      dt.fields["iso"].flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
check("日期 summary 非空（实得 \(dt.fields["summary"] ?? "nil")）",
      !(dt.fields["summary"] ?? "").isEmpty)

// raw 永远保留原文（可追溯）
for (text, _) in positives {
    check("raw 保留原文：\(text)", run(text).raw == text)
}

// MARK: - 5. 置信度与来源

print("── 5. 置信度 / 来源 ──")
// 不变式的真正意义：**写入类动作只在置信 >0.5 时出现**。
// 所以这里守两条：① 强格式 ≥0.9（地址弱命中 ≥0.75）② 兜底 text 必须 <0.5（第 2 节已断言）。
let strongKinds: Set<IntentKind> = [.express, .amount, .datetime, .link, .contact]
for (text, kind) in positives {
    let c = run(text).confidence
    let floor: Double = strongKinds.contains(kind) ? 0.9 : 0.75
    check("[\(kind.rawValue)] 置信 ≥\(floor)（实得 \(c)）：\(text)", c >= floor)
    check("[\(kind.rawValue)] 来源 = rule：\(text)", run(text).provenance == .rule)
}
check("全部正例都高于 0.5 动作门槛", positives.allSatisfy { run($0.0).confidence > 0.5 })
check("title 非空", positives.allSatisfy { !run($0.0).title.isEmpty })

// MARK: - 6. 边界：空串 / 超长 / 换行

print("── 6. 边界 ──")
let empty = run("")
check("空串 → text", empty.kind == .text)
check("空串置信 0", empty.confidence == 0)
let longText = String(repeating: "这是一段很长的普通文本。", count: 200)
check("超长文本不崩且 → text", run(longText).kind == .text)
let multiline = "https://example.com/x\n13812345678"
check("多行不崩（取首个强格式即可）", [IntentKind.link, .contact].contains(run(multiline).kind))

print("\n———————————————")
print(failures == 0 ? "✅ 全部通过 \(total)/\(total)" : "❌ 失败 \(failures)/\(total)")
exit(failures == 0 ? 0 : 1)
