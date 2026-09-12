// 诊断上报数据组装 + 离线队列单元测试（Linux 本地预检用，纯 Foundation）
//
// 编译方式（check_swift.sh 第 4 步；多文件编译时只有 main.swift 允许顶层代码，
// 因此脚本会把本文件复制成 /tmp/ql_diag_main/main.swift 再编译）：
//   cp scripts/test_diag.swift /tmp/ql_diag_main/main.swift
//   swiftc -swift-version 6 -o /tmp/test_diag /tmp/ql_diag_main/main.swift \
//          qingliao/Core/DiagnosticsPayload.swift qingliao/Core/DiagnosticsStore.swift
// 直接编译被测源文件本身（不是副本），因此覆盖的是真实代码。

import Foundation

// Swift 6 语言模式下 main.swift 顶层代码是 @MainActor 隔离的，
// 而 check() 是 nonisolated 全局函数 → 计数器显式标注 nonisolated(unsafe)。
nonisolated(unsafe) var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

let env = DiagEnv(version: "3.4.29", build: "433",
                  device: "iPhone17,2", os: "26.0", network: "wifi")

// MARK: 1. 事件组装

let ev = DiagnosticsPayload.makeEvent(kind: "hang", env: env,
                                      summary: "主线程卡顿 812ms",
                                      stack: "0 qingliao 0x1\n1 UIKitCore 0x2",
                                      durationMs: 812, ts: 1770000000, id: "fixed1")
check("类型=hang", ev.kind == "hang")
check("版本/构建号落位", ev.version == "3.4.29" && ev.build == "433")
check("设备/系统落位", ev.device == "iPhone17,2" && ev.os == "26.0")
check("网络类型落位", ev.network == "wifi")
check("时长落位", ev.durationMs == 812)
check("app 标识固定", ev.app == "qingliao-ios")
check("id 可控", ev.id == "fixed1")

let autoId = DiagnosticsPayload.makeEvent(kind: "crash", env: env, summary: "x")
check("自动 id 为 16 位十六进制", autoId.id.count == 16 && autoId.id.allSatisfy { $0.isHexDigit })
check("负时长被钳到 0", DiagnosticsPayload.makeEvent(kind: "hang", env: env, summary: "x", durationMs: -5).durationMs == 0)

// 摘要 / 栈长度收敛（clamp 会追加 “…(截断)” 共 5 字符）
let longSummary = String(repeating: "崩", count: 500)
let trimmed = DiagnosticsPayload.makeEvent(kind: "crash", env: env, summary: longSummary)
check("摘要截断到上限", trimmed.summary.count <= DiagnosticsPayload.maxSummaryChars + 5
      && trimmed.summary.hasSuffix("…(截断)"))
let longStack = String(repeating: "s", count: 9000)
let trimmedStack = DiagnosticsPayload.makeEvent(kind: "crash", env: env, summary: "x", stack: longStack)
check("调用栈截断到上限", trimmedStack.stack.count <= DiagnosticsPayload.maxStackChars + 5
      && trimmedStack.stack.hasSuffix("…(截断)"))

// 崩溃事件：只取 detail 首行做摘要
let crashEv = DiagnosticsPayload.makeCrashEvent(
    type: "NSException",
    detail: "NSInvalidArgumentException: 出错\n第二行不该进摘要",
    stack: "0 qingliao 0x3", env: env, ts: 1770000001)
check("崩溃摘要取首行", crashEv.summary == "NSException: NSInvalidArgumentException: 出错")
check("崩溃栈含调用栈", crashEv.stack.contains("0 qingliao 0x3"))
check("崩溃时长为 0", crashEv.durationMs == 0)

// MARK: 2. 隐私白名单 / 黑名单

let (clean, dropped) = DiagnosticsPayload.sanitize([
    "id": "a", "kind": "crash", "summary": "摘要",
    "token": "SECRET", "content": "用户聊天原文", "password": "123",
    "X-Auth-Token": "SECRET2", "unknownField": "whatever",
])
check("白名单字段保留", clean["id"] as? String == "a" && clean["summary"] as? String == "摘要")
check("token 被剔除", clean["token"] == nil)
check("content 被剔除", clean["content"] == nil)
check("password 被剔除", clean["password"] == nil)
check("X-Auth-Token 命中黑名单", DiagnosticsPayload.isBlockedKey("X-Auth-Token"))
check("非白名单字段不上行", clean["unknownField"] == nil)
check("dropped 记录被剔除字段名", dropped.contains("token") && dropped.contains("content")
      && dropped.contains("password") && dropped.contains("X-Auth-Token"))

// 上报 body 键集 == 白名单（无多余字段，无泄露）
let body = DiagnosticsPayload.reportBody(ev)
check("body 键集等于白名单", Set(body.keys) == DiagnosticsPayload.allowedKeys)
check("body 无黑名单键", DiagnosticsPayload.blockedKeysIn(body).isEmpty)
check("body 内容正确", (body["summary"] as? String) == "主线程卡顿 812ms"
      && (body["durationMs"] as? Int) == 812 && (body["network"] as? String) == "wifi")
check("body 无用户聊天字段", body["content"] == nil && body["text"] == nil && body["message"] == nil)

let batch = DiagnosticsPayload.batchBody([ev, crashEv])
check("批量 body 含 events 数组", (batch["events"] as? [[String: Any]])?.count == 2)
if let arr = batch["events"] as? [[String: Any]] {
    check("批量内每条都无黑名单键", arr.allSatisfy { DiagnosticsPayload.blockedKeysIn($0).isEmpty })
} else {
    check("批量内每条都无黑名单键", false)
}

// MARK: 3. 编解码 / 裁剪

let encoded = DiagnosticsPayload.encode([ev, crashEv])
let decoded = DiagnosticsPayload.decode(encoded)
check("编码后解码往返一致", decoded == [ev, crashEv])
check("损坏数据解码为空数组", DiagnosticsPayload.decode(Data("not json".utf8)).isEmpty)

let many = (0..<60).map { i in
    DiagnosticsPayload.makeEvent(kind: "hang", env: env, summary: "第\(i)条",
                                 durationMs: i, ts: Double(i), id: "h\(i)")
}
let capped = DiagnosticsPayload.capEvents(many, limit: 50)
check("裁剪保留最新 50 条", capped.count == 50 && capped.first?.id == "h10" && capped.last?.id == "h59")
check("不足上限时原样返回", DiagnosticsPayload.capEvents([ev], limit: 50).count == 1)

// MARK: 4. 离线队列 / 本地历史（注入临时目录，不碰真实沙盒）

let tmp = NSTemporaryDirectory() + "ql_diag_test_\(ProcessInfo.processInfo.processIdentifier)"
DiagnosticsStore.setBaseDir(tmp)
DiagnosticsStore.setEnv(env)

DiagnosticsStore.recordHang(durationMs: 700, stack: "0 qingliao 0x9")
DiagnosticsStore.recordCrash(type: "Signal(11)", detail: "SIGSEGV", stack: "0 qingliao 0xa", ts: 1770000100)
check("队列累计 2 条", DiagnosticsStore.pendingCount() == 2)
check("历史累计 2 条", DiagnosticsStore.historyEvents().count == 2)
check("历史上报带环境快照", DiagnosticsStore.historyEvents().allSatisfy { $0.version == "3.4.29" && $0.device == "iPhone17,2" })
check("历史按时间倒序（最新在前）", (DiagnosticsStore.historyEvents().first?.ts ?? 0) >= (DiagnosticsStore.historyEvents().last?.ts ?? 0))

// 队列落盘文件真实存在
check("队列文件已落盘", FileManager.default.fileExists(atPath: DiagnosticsStore.pendingPath()))
check("历史文件已落盘", FileManager.default.fileExists(atPath: DiagnosticsStore.historyPath()))

// 上报成功后出队
let ids = DiagnosticsStore.pendingEvents().map { $0.id }
DiagnosticsStore.removePending(ids: ids)
check("出队后队列为空", DiagnosticsStore.pendingCount() == 0)
check("出队不影响历史", DiagnosticsStore.historyEvents().count == 2)

// 队列上限：清空后灌 60 条（显式 ts 保证顺序确定）只留 50；历史只留 30
DiagnosticsStore.removePending(ids: DiagnosticsStore.pendingEvents().map { $0.id })
for i in 0..<60 {
    DiagnosticsStore.enqueue(DiagnosticsPayload.makeHangEvent(
        durationMs: 500 + i, stack: "0 qingliao 0xb\(i)", env: env, ts: 1000 + Double(i)))
}
check("队列上限 \(DiagnosticsPayload.maxPendingEvents) 条", DiagnosticsStore.pendingCount() == DiagnosticsPayload.maxPendingEvents)
check("历史上限 \(DiagnosticsPayload.maxHistoryEvents) 条", DiagnosticsStore.historyEvents().count == DiagnosticsPayload.maxHistoryEvents)
check("上限裁剪丢最旧（最新仍在）",
      DiagnosticsStore.pendingEvents().first?.ts == 1010
      && DiagnosticsStore.pendingEvents().last?.ts == 1059
      && DiagnosticsStore.pendingEvents().last?.summary == "主线程卡顿 559ms")

// 同 id 幂等
let dup = DiagnosticsPayload.makeEvent(kind: "hang", env: env, summary: "重复", id: "dup1")
DiagnosticsStore.enqueue(dup)
DiagnosticsStore.enqueue(dup)
check("同 id 幂等不重复入队", DiagnosticsStore.pendingEvents().filter { $0.id == "dup1" }.count == 1)

// MARK: 4b. v3.9.10 上报统计（诊断页「上报统计」行：待上报长期 0 时用来自证链路通）

check("初始统计为空", DiagnosticsStore.stats() == DiagnosticsStore.UploadStats())
DiagnosticsStore.recordUploadResult(ok: true, sent: 3, message: "已上报 3 条（120ms）")
var st = DiagnosticsStore.stats()
check("统计累计成功条数", st.totalUploaded == 3 && st.lastOK && st.lastAt > 0)
DiagnosticsStore.recordUploadResult(ok: false, sent: 2, message: "已上报 2/5 条，余下已缓存")
st = DiagnosticsStore.stats()
check("统计累计到 5 且上次为失败", st.totalUploaded == 5 && !st.lastOK)
check("统计文件已落盘", FileManager.default.fileExists(atPath: DiagnosticsStore.statsPath()))
check("统计可重读（落盘往返一致）", DiagnosticsStore.stats().lastMessage == "已上报 2/5 条，余下已缓存")
check("短时间：无记录显示「从未」", DiagnosticsPayload.shortTimeText(0) == "从未")
check("短时间：有值可格式化", DiagnosticsPayload.shortTimeText(1789222570).contains(":"))

// MARK: 4c. v3.9.10 修复项（确定性 id / 队列满不丢新事件 / 坏文件隔离 / 自测独立 kind）

let c1 = DiagnosticsPayload.makeCrashEvent(type: "Signal(11)", detail: "SIGSEGV", stack: "s", env: env, ts: 1770000200)
let c2 = DiagnosticsPayload.makeCrashEvent(type: "Signal(11)", detail: "SIGSEGV", stack: "s", env: env, ts: 1770000200)
check("同一崩溃跨启动 id 相同（enqueue 去重才生效）", c1.id == c2.id)
check("不同崩溃 id 不同",
      DiagnosticsPayload.makeCrashEvent(type: "Signal(6)", detail: "", stack: "s", env: env,
                                        ts: 1770000200).id != c1.id)

check("自测记录用独立 kind", DiagnosticsStore.recordSelfTest(durationMs: 500, stack: "x").kind == "selftest")
check("kindLabel 认识 selftest", DiagnosticsPayload.kindLabel("selftest") == "自测")

// 队列满时，刚入队的「更旧 ts」事件（崩溃 ts 可能比一堆卡顿都早）不能被当场裁掉
DiagnosticsStore.removePending(ids: DiagnosticsStore.pendingEvents().map { $0.id })
DiagnosticsStore.clearHistory()
for i in 0..<DiagnosticsPayload.maxPendingEvents {
    DiagnosticsStore.enqueue(DiagnosticsPayload.makeEvent(kind: "hang", env: env, summary: "填\(i)",
                                                          ts: 5000 + Double(i), id: "fill\(i)"))
}
let oldCrash = DiagnosticsPayload.makeCrashEvent(type: "Signal(11)", detail: "x", stack: "s", env: env, ts: 1)
DiagnosticsStore.enqueue(oldCrash)
check("队列满时新入队的更旧 ts 事件仍保留", DiagnosticsStore.pendingEvents().contains { $0.id == oldCrash.id })

// 坏队列文件：不当成空队列，隔离留证后再继续
DiagnosticsStore.removePending(ids: DiagnosticsStore.pendingEvents().map { $0.id })
try? Data("not json at all".utf8).write(to: URL(fileURLWithPath: DiagnosticsStore.pendingPath()))
DiagnosticsStore.enqueue(DiagnosticsPayload.makeEvent(kind: "hang", env: env, summary: "坏文件之后入队"))
let quarantined = ((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [])
    .contains { $0.contains("diag_pending.json.corrupt-") }
check("坏队列文件被隔离为 .corrupt-* 留证", quarantined)
check("坏文件不影响后续入队", DiagnosticsStore.pendingCount() == 1)

// 本节清过历史/队列，给下一节（展示文本）重新铺一条卡顿 + 一条崩溃
DiagnosticsStore.recordHang(durationMs: 812, stack: "0 qingliao\n1 UIKitCore")
DiagnosticsStore.recordCrash(type: "Signal(11)", detail: "SIGSEGV", stack: "0 qingliao", ts: 1770000300)

// MARK: 5. 展示文本（一键复制 / 导出）

// v3.9.10：uploadStats 不再有默认值（漏传会静默导出「统计全空」的报告）——这里传非空统计再断言
let bundle = DiagnosticsPayload.bundleText(env: env, events: DiagnosticsStore.historyEvents(),
                                           backend: "正常（42ms）", pendingCount: DiagnosticsStore.pendingCount(),
                                           uploadStats: DiagnosticsStore.UploadStats(
                                               totalUploaded: 7, lastOK: true,
                                               lastMessage: "已上报 2 条", lastAt: 1770000400))
check("诊断包含版本/构建号", bundle.contains("3.4.29") && bundle.contains("433"))
check("诊断包含设备与系统", bundle.contains("iPhone17,2") && bundle.contains("26.0"))
check("诊断包含网络与后端延迟", bundle.contains("wifi") && bundle.contains("42ms"))
check("诊断包含隐私声明", bundle.contains("不含聊天内容与凭据"))
check("诊断包列出记录", bundle.contains("卡顿") && bundle.contains("崩溃"))
check("单条详情含调用栈", DiagnosticsPayload.detailText(ev).contains("UIKitCore"))
check("单条详情含时长", DiagnosticsPayload.detailText(ev).contains("812ms"))
check("诊断包含上报统计行", bundle.contains("上报统计") && bundle.contains("累计 7 条"))
check("统计为空时也给出可读文案", DiagnosticsPayload.uploadStatsText(.init()) == "暂无上报记录")
check("待上报 0 且有上报记录 → 标注已全部上报",
      DiagnosticsPayload.pendingText(0, stats: .init(totalUploaded: 3, lastOK: true, lastMessage: "", lastAt: 0))
        == "0 条（已全部上报）")
check("待上报 >0 时直接给条数", DiagnosticsPayload.pendingText(4, stats: .init()) == "4 条")

// 网络类型映射
check("离线 → offline", DiagnosticsPayload.networkLabel(isCellular: false, isSatisfied: false) == "offline")
check("蜂窝 → cellular", DiagnosticsPayload.networkLabel(isCellular: true, isSatisfied: true) == "cellular")
check("Wi-Fi → wifi", DiagnosticsPayload.networkLabel(isCellular: false, isSatisfied: true) == "wifi")

// 清理
try? FileManager.default.removeItem(atPath: tmp)
DiagnosticsStore.setBaseDir(nil)

print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
exit(failures == 0 ? 0 : 1)
