import Foundation

// 启动会话策略真值表（v4.0.0）
// 覆盖：auto/last/new 三档 × 空闲时长边界（< / = / > 阈值）× 无记录（首装）× 时钟异常
//
// 🚨 本表**直接编译生产源码** `qingliao/Core/LaunchSession.swift`（由 check_swift.sh 传入）。
// 起因：v4.0.0 审查抓到真问题 —— 原先本表在表内另写一份镜像实现、且不编译生产源码，
// 于是「`>=` 改成 `>`」「默认 15 改掉」「nil 兜底翻转」「整条 touchLastActive 接线删掉」
// 这些真实回归**全绿**。现在 `LaunchSessionMode` / `defaultIdleMinutes` / `idleOptions`
// 与 `shouldOpenNewSession` / `idleMinutesSince` 全部来自生产源码，公式一改必红。
@MainActor
enum LaunchSessionTruthTable {
    /// 顶层只能有声明（要与生产源码多文件一起编译）→ 入口走这个 static 方法。
    /// 返回值给外层 main.swift 语义的调用方转成退出码（exit() 在非 main 文件里是 main 专属）。
    @discardableResult
    static func main() -> Int32 {
        run()
    }
}

@MainActor
func run() -> Int32 {
    var pass = 0, fail = 0
    func check(_ name: String, _ ok: Bool) {
        if ok { pass += 1; print("✅ \(name)") } else { fail += 1; print("❌ \(name)") }
    }

    // MARK: - 1. 生产常量（需求原文：默认自动 + 15 分钟）
    check("默认阈值 = 15 分钟（需求原文）", LaunchSessionMode.defaultIdleMinutes == 15)
    check("默认档位是自动", LaunchSessionMode(rawValue: "auto") == .auto)
    check("三档齐全（自动/上次会话/新对话）",
          Set(LaunchSessionMode.allCases.map(\.rawValue)) == ["auto", "last", "new"])
    check("阈值档位含 15 且全为正",
          LaunchSessionMode.idleOptions.contains(15)
          && LaunchSessionMode.idleOptions.allSatisfy { $0 > 0 })
    check("三档标题与需求原文一致",
          LaunchSessionMode.auto.title == "自动"
          && LaunchSessionMode.last.title == "上次会话"
          && LaunchSessionMode.new.title == "新对话")

    // MARK: - 2. 新对话档：无视时长，永远新
    for idle in [nil, 0, 1, 14, 15, 16, 999, 100_000] as [Int?] {
        check("新对话：空闲 \(idle.map(String.init) ?? "无记录") → 一律开新",
              shouldOpenNewSession(mode: .new, idleMinutes: idle, threshold: 15))
    }

    // MARK: - 3. 上次会话档：无视时长，永远续上次
    for idle in [nil, 0, 1, 14, 15, 16, 999, 100_000] as [Int?] {
        check("上次会话：空闲 \(idle.map(String.init) ?? "无记录") → 一律回上次",
              !shouldOpenNewSession(mode: .last, idleMinutes: idle, threshold: 15))
    }

    // MARK: - 4. 自动档边界：14 续 / **15 开新** / 16 开新
    check("自动：空闲 14 分钟 → 续上次（未到阈值）",
          !shouldOpenNewSession(mode: .auto, idleMinutes: 14, threshold: 15))
    check("自动：空闲正好 15 分钟 → 开新对话（≥ 边界）",
          shouldOpenNewSession(mode: .auto, idleMinutes: 15, threshold: 15))
    check("自动：空闲 16 分钟 → 开新对话",
          shouldOpenNewSession(mode: .auto, idleMinutes: 16, threshold: 15))
    check("自动：空闲 0（刚离开）→ 续上次",
          !shouldOpenNewSession(mode: .auto, idleMinutes: 0, threshold: 15))
    check("自动：隔一整夜 → 开新对话",
          shouldOpenNewSession(mode: .auto, idleMinutes: 600, threshold: 15))

    // MARK: - 5. 自动档 + 无记录 = 保守回上次（不许凭空丢上下文）
    check("自动：无记录（首装）→ 续上次，不凭空开新",
          !shouldOpenNewSession(mode: .auto, idleMinutes: nil, threshold: 15))

    // MARK: - 6. 阈值可调：改档位后判定跟着变
    for t in LaunchSessionMode.idleOptions {
        check("自动/阈值\(t)：\(t - 1) 分钟不开新、\(t) 分钟开新",
              !shouldOpenNewSession(mode: .auto, idleMinutes: t - 1, threshold: t)
              && shouldOpenNewSession(mode: .auto, idleMinutes: t, threshold: t))
    }

    // MARK: - 7. 毫秒 → 分钟换算（生产函数）
    let now = 1_700_000_000_000.0   // 固定基准，不依赖真实时钟
    func mins(_ m: Double) -> Double { now - m * 60_000 }

    check("换算：10 分钟前 = 10", idleMinutesSince(nowMs: now, lastActiveAtMs: mins(10)) == 10)
    check("换算：15 分钟前 = 15", idleMinutesSince(nowMs: now, lastActiveAtMs: mins(15)) == 15)
    check("换算：59.9 分钟截断为 59（不提前判超时）",
          idleMinutesSince(nowMs: now, lastActiveAtMs: mins(59.9)) == 59)
    check("换算：0（刚退后台）= 0", idleMinutesSince(nowMs: now, lastActiveAtMs: now) == 0)
    check("换算：90 分钟 = 90", idleMinutesSince(nowMs: now, lastActiveAtMs: mins(90)) == 90)

    // MARK: - 8. 无记录 / 非法时间戳
    check("无记录（键不存在，值 0）→ nil",
          idleMinutesSince(nowMs: now, lastActiveAtMs: 0) == nil)
    // 🚨 审查 LOW：未来时间戳（时钟回拨 / 改机时间）算出来是负数，会让「自动」档永远判「刚离开过」
    check("未来时间戳（时钟回拨）→ nil（不当成 0 分钟）",
          idleMinutesSince(nowMs: now, lastActiveAtMs: now + 60_000) == nil)
    check("负时间戳 → nil", idleMinutesSince(nowMs: now, lastActiveAtMs: -1) == nil)

    // MARK: - 9. 端到端：换算 + 判定串起来
    check("端到端：15.5 分钟前离开 → 自动档开新（截断成 15 → ≥15）",
          shouldOpenNewSession(mode: .auto,
                               idleMinutes: idleMinutesSince(nowMs: now, lastActiveAtMs: mins(15.5)),
                               threshold: 15))
    check("端到端：14.9 分钟前离开 → 自动档续上次（截断成 14 → <15）",
          !shouldOpenNewSession(mode: .auto,
                                idleMinutes: idleMinutesSince(nowMs: now, lastActiveAtMs: mins(14.9)),
                                threshold: 15))
    check("端到端：首装无记录 → 自动档续上次",
          !shouldOpenNewSession(mode: .auto,
                                idleMinutes: idleMinutesSince(nowMs: now, lastActiveAtMs: 0),
                                threshold: 15))

    // MARK: - 10. 源码级接线护栏（判定搬进纯函数后，ChatStore 不得再自带一份公式）
    func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    let store = read("qingliao/Core/ChatStore.swift")
    let app = read("qingliao/QingliaoApp.swift")
    check("读得到 ChatStore 源码（路径没被挪）", !store.isEmpty)
    check("读得到 App 源码（路径没被挪）", !app.isEmpty)
    check("自动档真的读了 lastActiveAt（接线没被删）",
          store.contains("UserDefaultsKey.lastActiveAt"))
    check("判定走生产函数 shouldOpenNewSession（ChatStore 不再自带公式）",
          store.contains("shouldOpenNewSession(mode:"))
    check("ChatStore 里没有第二份 `idle >= threshold` 公式（单一真源）",
          !store.contains(">= threshold"))
    check("换算走生产函数 idleMinutesSince（单一真源）",
          store.contains("idleMinutesSince(nowMs:"))
    // 🚨 审查 F1 抓到的「假修」：上一版这条只查字符串存在，于是把
    //   `if phase != .active { ... }` 塞进 `if phase == .background` 块体内（块内恒为 true、
    //   等价于 .background，.inactive 场景一个没补上）也照样全绿。
    // 现在改成**位置断言**：touchLastActive 的调用必须落在 background 块的闭合花括号之后。
    let bgOpen = app.range(of: "if phase == .background {")
    let touchAt = app.range(of: "ChatStore.touchLastActive()")
    if let bg = bgOpen, let t = touchAt {
        // 取 background 块内最后一个嵌套闭合前的位置：数花括号深度
        // ⚠️ 索引一律走 distance(from:) —— 直接把两个 String.Index 相减在 Swift 6 下不成立。
        let seg = String(app[bg.upperBound...])
        let rel = seg.distance(from: seg.startIndex, to: t.lowerBound)
        var depth = 1
        for ch in seg.prefix(rel) {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
        }
        check("🚨 记录时刻的判定在 background 块**外**（.inactive 也真能记）", depth == 0)
    } else {
        check("读得到 background 分支与 touchLastActive 调用", false)
    }
    check("判定条件本身是「非 active」（含 .inactive）",
          app.contains("if phase != .active { ChatStore.touchLastActive() }"))
    // 前台长时间使用后被杀：补记「最近使用时刻」，idle 取两者较晚
    check("记时刻时同时刷新最近使用时刻（覆盖前台被杀）",
          store.contains("UserDefaultsKey.lastUsedAt"))
    check("idle 取离开时刻与最近使用时刻的较晚者",
          store.contains("lastActiveAtMs: max(away, used)"))
    check("冷启动走策略而不是裸 loadLastSession",
          app.contains("chat.applyLaunchSessionPolicy(auth: auth)"))
    // 🚨 审查 HIGH：冷启动开新对话前必须先保住「回到上次会话」的路
    check("🚨 开新对话前先留旧会话退路（keepLastSessionAsFallback）",
          store.contains("await keepLastSessionAsFallback(auth: auth)"))
    check("🚨 且退路只存 lastLoadedSession，不动 sessionId（否则就不是新对话了）",
          store.components(separatedBy: "func keepLastSessionAsFallback").last!
              .contains("lastLoadedSession = match"))
    check("开新对话后补投静默 /new（gateway 上下文一并重置）",
          store.contains("silentGatewayResetForNewSession"))
    check("阈值读法走 NSNumber 桥（Double 落盘也不静默退回 15）",
          store.contains("(o as? NSNumber)?.intValue"))
    // 🚨 审查 F6（HIGH 根因）：空会话不得夺「当前会话」指针
    let newBody = store.components(separatedBy: "func newSession()").last!.prefix(1200)
    check("🚨 newSession 不再无条件覆写当前会话指针", !newBody.contains("defaults.set(sessionId, forKey: sessionKey)"))
    check("🚨 空会话 id 先进 pendingSessionId（不夺指针）", newBody.contains("pendingSessionId = sessionId"))
    check("🚨 指针只在落库后交接 claimPendingSessionId", store.contains("func claimPendingSessionId()"))
    check("首条用户消息落地即交接指针", store.contains("claimPendingSessionId()"))
    // 重置请求不得用空 model（否则后端 400 → 静默失效）
    check("重置请求不发空 model（后端 400 会静默失效）", !store.contains("string(forKey: \"qingliao_model\") ?? \"\""))
    check("重置请求与 resolveModel 同优先级（Agent 模型优先）",
          store.contains("UserDefaultsKey.agentModel"))
    // 冷启动这次重置不得凭空弹「登录已过期」
    check("冷启动重置保存/恢复过期标志（不凭空弹横幅）",
          store.contains("let expiredBefore = auth.sessionExpired"))
    // 🚨 CI 教训（v4.0.0 Archive 失败）：`UserDefaultsKey.model` / `.provider` 是我**凭空写的**，
    //   仓里没有这两个成员 → xcodebuild 报 "type 'UserDefaultsKey' has no member 'model'"。
    //   `-parse` 查不出（不解析成员），只有真编译才发现。故这里钉住：凡引用的 key 成员必须在
    //   Models.swift 里真实存在。
    let modelsSrc = read("qingliao/Core/Models.swift")
    for key in ["model", "provider", "agentModel", "agentProvider", "lastActiveAt", "lastUsedAt"] {
        check("UserDefaultsKey.\(key) 在 Models.swift 里真实存在（防凭空造 API）",
              modelsSrc.contains("static let \(key)"))
    }
    check("UserDefaultsKey 复用既有 key 字面量（不另起一套）",
          modelsSrc.contains("\"qingliao_model\"") && modelsSrc.contains("\"qingliao_provider\""))

    print("\n———————————————")
    print(fail == 0 ? "🎉 全部通过（\(pass) 项）" : "❌ \(fail) 个失败（\(pass) 通过）")
    return fail == 0 ? 0 : 1
}

// 本表**不含**顶层调用：它要与生产源码一起编译（多文件模式），顶层只允许声明。
// 入口由 check_swift.sh 生成的 main.swift 调用 → 见该脚本 5b 步。
// 单文件手测时可用 `swiftc -parse-as-library` + 自行加 main。
