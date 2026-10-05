// v4.0.22 设置页搜索真值表 —— Linux 本地预检用，纯 Foundation（编译真源 SettingsSearchIndex.swift）
//
// 编译运行（仓库根目录，权威入口是 check_swift.sh 第 61 段）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_settings_search \
//       scripts/ql_settings_search/truth_table_settings_search.swift \
//       qingliao/Core/SettingsSearchIndex.swift
//
// 两类断言：
//   ① 匹配规则（纯逻辑）：空查询/多词/大小写/无命中/检索范围不含分组名。
//      空查询必须返回空数组 —— 返回「全部」的话设置页一打开就顶着三十多条结果。
//   ② **路由真值（源级）**：索引里每条 route 都必须在 SettingsCore 的 openSearchEntry switch 里
//      被处理，sec:* 路由必须有对应的 .id("…") 锚点与滚动赋值。漏一条的坏法是：
//      搜得到、点下去毫无反应 —— 编译不报、手点才现。
//   本表的反例（不该被搜出来的那批）占三分之一以上：结果越准用户才越敢用。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
struct SettingsSearchTruthTable {

    static let core = read("qingliao/Features/Settings/SettingsCore.swift")
    static let searchView = read("qingliao/Features/Settings/SettingsSearch.swift")

    /// 断言「某查询**不该**搜出某项」——反例集中的写法
    static func notContains(_ query: String, _ title: String, _ note: String) {
        negatives += 1
        check("反例：\(note)", !SettingsSearchIndex.match(query).contains { $0.title == title })
    }

    static func runAllTests() {
        let entries = SettingsSearchIndex.entries
        let routes = Set(entries.map(\.route))

        // ── 1. 索引本身 ──
        positives += 1
        // 精确钉死条数（不是 ≥30）：整条连同 route 一起被删时，下面的路由核验不会红 —— 只有条数能兜住。
        // 新增设置行时必须同步加索引 + 改这里的数（有意的摩擦：漏了就是「肉眼可见却搜不到」）。
        check("索引条数与设置页对齐（当前 \(entries.count)，期望 38）", entries.count == 38)
        positives += 1
        check("id 全表唯一（route 会复用 → id 必须拼 title）",
              Set(entries.map(\.id)).count == entries.count)
        positives += 1
        check("每条都有标题/图标/分组/route（缺一项就是「搜不到」或「点不动」）",
              entries.allSatisfy {
                  !$0.title.isEmpty && !$0.icon.isEmpty && !$0.group.isEmpty && !$0.route.isEmpty
              })
        positives += 1
        check("分组名只用设置页那几类（拼错 = 结果行副标题显示野分组）",
              Set(entries.map(\.group)).isSubset(of: ["账号与安全", "连接与模型", "AI 智能",
                                                      "数据与自动化", "Agent 设置", "外观与显示", "关于"]))

        // ── 2. 路由真值：每条 route 都要在 SettingsCore.openSearchEntry 里被处理，且**落到对的目的地** ──
        // ⚠️ 只断言 `case "x":` 出现过是不够的（审查实测）：把 `case "pet": showPetStudio = true`
        // 改成 `showAbout = true`，所有断言照样全绿 —— 用户搜「宠物」点下去打开「关于」。
        // 所以先把 switch 体切出来（不是扫整个文件），再逐条核对「这条 route 打开了哪个目的地」。
        let fnBody: String = {
            guard let s = core.range(of: "func openSearchEntry") else { return "" }
            let tail = String(core[s.lowerBound...])
            guard let e = tail.range(of: "default: break") else { return tail }
            return String(tail[..<e.upperBound])
        }()
        positives += 1
        check("切得出 openSearchEntry 的 switch 体（切不出=后面两条路由断言在空转）",
              fnBody.contains("switch entry.route") && fnBody.count > 300)

        /// 取某条 route 的 case 块（到下一个 `case "` 为止）—— 兼容单行与多行写法
        func caseBlock(_ route: String) -> String {
            guard let r = fnBody.range(of: "case \"\(route)\":") else { return "" }
            let rest = String(fnBody[r.upperBound...])
            if let next = rest.range(of: "case \"") { return String(rest[..<next.lowerBound]) }
            return rest
        }

        // route → 期望目的地（弹窗类=showX；sec:* 类=滚动锚点），与 SettingsSearchIndex 文件头约定一一对应
        let targets: [(String, String)] = [
            ("password", "showPasswordSheet"), ("conn", "showConnSettings"), ("model", "showModelSheet"),
            ("wechatChannel", "showWechatChannel"), ("ha", "showHASettings"), ("mcp", "showMCPSettings"),
            ("mail", "showMailSettings"), ("cloudDrive", "showCloudDrive"), ("appPermissions", "showAppPermissions"),
            ("localModels", "showLocalModels"), ("kb", "showKB"), ("memory", "showMemory"),
            ("cardGallery", "showCardGallery"), ("secrets", "showSecrets"), ("tasks", "showTasks"),
            ("history", "showHistory"), ("logs", "showLogs"), ("diagnostics", "showDiagnostics"),
            ("pinPath", "connOpenPinPath"), ("lifeCards", "showLifeCards"), ("quickReminder", "showQuickReminder"),
            ("filesManager", "showFilesManager"), ("proactive", "showProactive"),
            ("agentModel", "showAgentModelSheet"), ("agentHelp", "showAgentHelp"),
            ("agentKeywords", "showAgentKeywords"), ("agentMemory", "showAgentMemory"),
            ("appearance", "showAppearance"), ("pet", "showPetStudio"),
            ("homeShortcuts", "showHomeShortcuts"), ("about", "showAbout"),
            ("sec:account", "sec-account"), ("sec:ai", "sec-ai"), ("sec:appearance", "sec-appearance"),
        ]
        let badTargets = targets.filter { route, dest in
            let block = caseBlock(route)
            guard !block.isEmpty else { return true }
            return route.hasPrefix("sec:") ? !block.contains("searchScrollTarget = \"\(dest)\"")
                                          : !block.contains("\(dest) = true")
        }
        positives += 1
        check("\(targets.count) 条 route 都落到对的目的地（点错地方 = 比「没反应」更坏）"
              + (badTargets.isEmpty ? "" : "（错：\(badTargets.map { "\($0.0)→\($0.1)" }.joined(separator: ", "))）"),
              badTargets.isEmpty)

        // 索引里出现的 route 必须都在这张表里（新加 route 忘了写目的地 → 立刻红，不留暗角）
        let unmapped = routes.subtracting(targets.map { $0.0 })
        positives += 1
        check("索引里的 route 没有漏登记目的地的" + (unmapped.isEmpty ? "" : "（漏：\(unmapped.sorted().joined(separator: ", "))）"),
              unmapped.isEmpty)

        let unhandled = routes.filter { caseBlock($0).isEmpty }
        positives += 1
        check("全部 \(routes.count) 条 route 都在 openSearchEntry 里被处理"
              + (unhandled.isEmpty ? "" : "（缺失：\(unhandled.sorted().joined(separator: ", "))）"),
              unhandled.isEmpty)

        // ── 3. sec:* 路由必须有锚点与滚动赋值 ──
        let secRoutes = routes.filter { $0.hasPrefix("sec:") }.sorted()
        let badAnchors = secRoutes.filter {
            let anchor = $0.replacingOccurrences(of: "sec:", with: "sec-")
            return !(core.contains(".id(\"\(anchor)\")") && core.contains("= \"\(anchor)\""))
        }
        positives += 1
        check("\(secRoutes.count) 个「滚到分组」路由的锚点/赋值都在"
              + (badAnchors.isEmpty ? "" : "（缺失：\(badAnchors.joined(separator: ", "))）"),
              !secRoutes.isEmpty && badAnchors.isEmpty)

        // ── 4. 匹配规则 ──
        let model = SettingsSearchIndex.match("模型")
        positives += 1
        check("「模型」命中 4 项（模型管理/微信通道模型/Agent 模型/管理模型），当前 \(model.count)",
              model.count == 4)
        positives += 1
        check("「模型」首条是「模型管理」（按设置页从上到下的顺序）", model.first?.title == "模型管理")

        let multi = SettingsSearchIndex.match("模型 管理")
        positives += 1
        check("多词：每个词都要命中（「模型 管理」含「模型管理」）",
              multi.contains { $0.title == "模型管理" })
        negatives += 1
        check("反例：多词查询不因命中一个词就返回（「模型 管理」不含「AI 记忆」）",
              !multi.contains { $0.title == "AI 记忆" })

        positives += 1
        check("大小写不敏感：mcp 与 MCP 结果一致",
              SettingsSearchIndex.match("mcp").map(\.id) == SettingsSearchIndex.match("MCP").map(\.id))
        positives += 1
        check("英文别名：face id 能搜到「Face ID 登录」（关键词里有 faceid）",
              SettingsSearchIndex.match("face id").contains { $0.title == "Face ID 登录" })

        // ── 5. 用户最可能搜的词都要能落到某个设置项（聚合断言，缺失时打印是谁）──
        let expected: [(String, String)] = [
            ("记忆", "AI 记忆"), ("推送", "微信推送"), ("震动", "震动反馈"),
            ("网盘", "网盘接入"), ("定时", "定时任务"), ("密码", "密码管理"),
            ("宠物", "AI形象"), ("日志", "日志"), ("更新", "关于轻聊"),
        ]
        let misses = expected.filter { pair in
            !SettingsSearchIndex.match(pair.0).contains { $0.title == pair.1 }
        }
        positives += 1
        check("9 个常用词都能落到目标设置项"
              + (misses.isEmpty ? "" : "（缺失：\(misses.map { "\($0.0)→\($0.1)" }.joined(separator: ", "))）"),
              misses.isEmpty)

        // ── 6. 反例集：不该被搜出来的（不准 = 不敢用）──
        negatives += 1
        check("反例：空查询 → 空数组（绝不是「返回全部」）", SettingsSearchIndex.match("").isEmpty)
        negatives += 1
        check("反例：纯空格查询 → 空数组", SettingsSearchIndex.match("   ").isEmpty)
        negatives += 1
        check("反例：无关键词命中 → 空（不许瞎返回）", SettingsSearchIndex.match("赵四").isEmpty)
        negatives += 1
        check("反例：设置里没有的「删除」不该瞎命中", SettingsSearchIndex.match("删除").isEmpty)

        // 分组名不可搜：「连接与模型」含「模型」二字，算进去会让搜「模型」带出整组
        notContains("模型", "连接设置", "搜「模型」不把「连接设置」带出来（分组名不参与检索）")
        notContains("模型", "邮件接入", "搜「模型」不把「邮件接入」带出来（分组名不参与检索）")
        notContains("提醒", "文件管理", "搜「提醒」不把「文件管理」带出来")
        notContains("日志", "诊断", "搜「日志」不把「诊断」带出来（两件事分开）")
        notContains("密码", "App 锁", "搜「密码」不把「App 锁」带出来（该搜「锁」）")
        notContains("推送", "定时提醒", "搜「推送」不把「定时提醒」带出来")
        notContains("震动", "首页快捷卡片", "搜「震动」不把「首页快捷卡片」带出来（同组但不同事）")
        notContains("记忆", "知识库", "搜「记忆」不把「知识库」带出来")
        notContains("网盘", "邮件接入", "搜「网盘」不把「邮件接入」带出来")
        notContains("更新", "诊断", "搜「更新」不把「诊断」带出来")
        notContains("宠物", "AI 记忆", "搜「宠物」不把「AI 记忆」带出来")

        // ── 7. 视图接线（源级护栏：入口/结果区被删掉时编译不报、功能静默消失）──
        positives += 1
        check("设置页挂了搜索框", core.contains("SettingsSearchBar(text: $settingsQuery)"))
        positives += 1
        check("设置页挂了结果区", core.contains("SettingsSearchList(query: settingsQuery)"))
        positives += 1
        check("结果点击有落点（openSearchEntry）", core.contains("openSearchEntry("))
        positives += 1
        check("结果区真的按查询过滤（不是把整个索引铺出来）",
              searchView.contains("SettingsSearchIndex.match("))
        positives += 1
        check("搜索框是自绘的（不用系统 .searchable，避免顶栏观感分叉）",
              !core.contains(".searchable("))
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
