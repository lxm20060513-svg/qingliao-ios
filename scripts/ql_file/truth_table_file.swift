// MARK: - #17 「AI 成品文件卡」真值表
//
// 口径（协议：ql-card JSON 里与 form 同级、互斥的可选段 file）：
//   {"type":"file","title":"周报.docx","file":{"path":"office/周报.docx","name":"周报.docx","kind":"docx","size":36765}}
//   · path 必填（相对后端允许根的路径，本批只有 `office/` 这一条别名根）；
//   · name 缺省用 path 最后一段；kind 缺省由 name 扩展名推断；size 缺省 0（未知，不显示大小）；
//   · kind 只认 docx/xlsx/pptx/pdf/image/other，未知值一律 other；
//   · **缺 path / path 为空 → 整段丢弃**（退化成普通只读卡，绝不崩、绝不出「查看」按钮）。
//
// 落点：
//   · 协议/解析  Core/AgentCardParser.swift（Kind.file + File/File.Kind + 容错解析 + plainText/isEmpty）
//   · 共享下载   Core/FilesManagerKit.swift（RemoteFiles.fetchData / fetchToTemp，单一真源；
//                原 SettingsData 私有 filesFailureReason / writeTemp 收归此处）
//   · 视图      Features/Chat/AgentCardFileSection.swift（独立小 View，卡片自查 AuthStore）
//   · 接线      AgentResultCard（file 段 → AgentCardFileSection，与 form 段并列互斥）
//
// 为什么值得钉：下面每一条**坏了都不报错** ——
//   ① 解析没把 file 段收进来 / 结构改名 → 卡片画面永远不出现（编译过、其它表全绿）；
//   ② 缺 path 没被丢弃 → 出「查看」按钮但点下去下载空路径，或直接崩（path 为空的落盘/URL 拼接）；
//   ③ 下载路径在视图里再拼一次 → 与共享入口分叉，改一处漏一处（query 编码/别名根前缀漂移）；
//   ④ 卡片自己拼 URL / 自己写 UserDefaults → 绕过单一真源（清缓存/换键名时两张表各自失忆）；
//   ⑤ `.quickLookPreview` 漏 import QuickLook → **本地 -parse 不报、CI Archive 才炸**（本仓其它使用点都带这行）。
//
// 单文件（读源文件做护栏，不 import 项目代码）→ run_unit 直接编跑。**必须 cwd = 仓库根**
// （下面全是相对路径，漂移会静默全绿 → 前置哨兵会报红）。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// 剥掉 `//` 行注释（注释里刻意写了「原来那样是错的」的说明，直接 grep 原文会被自己的注释判红）
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            let head = line[line.startIndex..<r.lowerBound]
            if head.filter({ $0 == "\"" }).count % 2 == 1 { return String(line) }
            return String(head)
        }
        .joined(separator: "\n")
}

func countOf(_ needle: String, in hay: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return hay.components(separatedBy: needle).count - 1
}

/// 取标记之间的片段（nil = 标记缺失 → 调用方必须判失败，不能静默放过）
func closureBody(_ text: String, from: String, to: String) -> String? {
    guard let a = text.range(of: from)?.upperBound,
          let b = text.range(of: to, range: a..<text.endIndex)?.lowerBound else { return nil }
    return String(text[a..<b])
}

/// 两标记之间是否只有空白（「紧跟/相邻」类断言的唯一可靠写法）
func onlyWhitespaceBetween(_ text: String, _ a: String, _ b: String) -> Bool {
    guard let ra = text.range(of: a)?.upperBound,
          let rb = text.range(of: b, range: ra..<text.endIndex)?.lowerBound else { return false }
    return text[ra..<rb].allSatisfy { $0.isWhitespace }
}

/// 位置比较（after 必须先于 before 出现）
func orderedPair(_ text: String, after: String, before: String) -> Bool {
    guard let a = text.range(of: after)?.lowerBound,
          let b = text.range(of: before)?.lowerBound else { return false }
    return a < b
}

// MARK: 读源

let parserPath = "qingliao/Core/AgentCardParser.swift"
let sectionPath = "qingliao/Features/Chat/AgentCardFileSection.swift"
let cardPath = "qingliao/Features/Chat/AgentResultCard.swift"
let kitPath = "qingliao/Core/FilesManagerKit.swift"
let settingsPath = "qingliao/Features/Settings/SettingsData.swift"

let parserRaw = src(parserPath)
let sectionRaw = src(sectionPath)
let cardRaw = src(cardPath)
let kitRaw = src(kitPath)
let settingsRaw = src(settingsPath)

let parser = code(parserRaw)
let section = code(sectionRaw)
let card = code(cardRaw)
let kit = code(kitRaw)
let settings = code(settingsRaw)

// 路径漂移必须炸（读不到文件时上面全是空串 —— 不钉住的话整表会静默全绿）
check("前置：五个源文件都读到了内容（路径漂移会静默全绿）",
      [parser, section, card, kit, settings].allSatisfy { $0.count > 500 })

// MARK: ① 解析层有 Kind.file 与 File 结构

check("① 解析层有 file 卡类型（Kind.file）", parser.contains("case file"))
check("① File 结构存在（Equatable, Sendable）", parser.contains("struct File: Equatable, Sendable"))
check("① File.kind 白名单齐全（docx/xlsx/pptx/pdf/image/other）",
      parser.contains("case docx, xlsx, pptx, pdf, image, other"))
check("① kind 归一化：未知值 → other（白名单外一律 other）", parser.contains("?? .other"))
check("① kind 缺省由扩展名推断的出口存在", parser.contains("static func infer(fromName"))
check("① 构造卡片时真的把 file 传进去了", parser.contains("file: file"))
check("① isEmpty 把 file 计入（只有文件段的卡不算空卡）", parser.contains("&& file == nil"))
check("① plainText 落文件段（只读降级/复制/导出不丢文件名）",
      parser.contains("if let file {") && parser.contains("文件：\\(file.name)"))

// MARK: ② file 段缺 path 时被丢弃（不是崩 / 不是空壳按钮）

let fileBlock = closureBody(parser, from: "let file: File? = {", to: "let card = AgentCard(") ?? ""
check("② 哨兵：file 解析切片必须真取到内容（取不到 = 下面恒真/恒假）", !fileBlock.isEmpty)
check("② 缺 path / path 为空 → 整段丢弃（guard !path.isEmpty else { return nil }）",
      fileBlock.contains("guard !path.isEmpty else { return nil }"))
check("② 丢弃是「返回 nil」而非抛错/崩（切片里有 return nil，无 fatalError / force unwrap path）",
      fileBlock.contains("return nil") && !fileBlock.contains("fatalError") && !fileBlock.contains("path!"))
// 空壳按钮防线：视图只在 file 段**存在**时被构造（file == nil → 不画「查看」按钮）
check("② 空壳按钮防线：AgentResultCard 只在 card.file 非空时构造文件段",
      card.contains("if let file = card.file {") && card.contains("AgentCardFileSection(file: file)"))

// MARK: ③ 下载路径只在一处构造（office/ 前缀不许在视图里再拼一次）

check("③ 下载 query 只在 FilesManagerKit 里构造一次（/api/files/download?path=）",
      countOf("/api/files/download?path=", in: kit) == 1)
check("③ 视图侧不出现下载 URL（不许自己拼 /api/files/...）",
      countOf("/api/files", in: section) == 0)
check("③ 视图侧不出现 `office/` 别名根前缀（path 由卡片直接下发，一键透传，不重拼）",
      countOf("office/", in: section) == 0)
check("③ 视图侧不出现 query 编码自造（path 编码只在 FilesManagerKit.queryEncoded）",
      countOf("queryEncoded", in: section) == 0)

// MARK: ④ 卡片走共享下载入口而非自己拼 URL / 自己写 UserDefaults

check("④ 文件卡走共享下载入口（RemoteFiles.fetchToTemp）", section.contains("RemoteFiles.fetchToTemp("))
check("④ 文件卡不直接调底层 auth.downloadFile（绕过共享入口）", !section.contains("downloadFile("))
check("④ 文件卡不写 UserDefaults（一切单一真源）", !section.contains("UserDefaults"))
check("④ 共享下载入口存在：fetchData", kit.contains("static func fetchData("))
check("② name 缺省取最后**非空**片段（path 以 / 结尾不许出空标题）",
      parser.contains(#"path.components(separatedBy: "/").filter { !$0.isEmpty }.last"#)
      && !parser.contains(#"rawName.isEmpty ? (path.components(separatedBy: "/").last ??"#))
check("④ 共享下载入口存在：fetchToTemp", kit.contains("static func fetchToTemp("))
check("④ 共享入口是唯一网络调用点（kit 里 auth.downloadFile(q) 恰 1 处）",
      countOf("auth.downloadFile(q)", in: kit) == 1)
check("④ 共享入口按 2xx + 非空判定成功（与设置页逐字一致）",
      kit.contains("if (200..<300).contains(code), !data.isEmpty { return .success(data) }"))
check("④ 失败文案收归共享（kit 有 failureReason 定义且不再有旧私有名）",
      countOf("static func failureReason(_ error: Error)", in: kit) == 1
      && countOf("func filesFailureReason", in: kit) == 0)
check("④ 落盘净化收归共享（kit 有 writeTemp 定义，走 safeLocalName）",
      countOf("static func writeTemp(_ data: Data, name: String)", in: kit) == 1
      && kit.contains("dir.appendingPathComponent(safeLocalName(name))")
      && kit.contains("appendingPathComponent(\"files_manager\""))
check("④ 设置页改用共享入口（不再自带一份失败文案 / 写盘）",
      countOf("RemoteFiles.fetchData(", in: settings) >= 1
      && countOf("RemoteFiles.failureReason(", in: settings) >= 1
      && countOf("RemoteFiles.writeTemp(", in: settings) >= 1
      && countOf("func filesFailureReason", in: settings) == 0
      && countOf("private func writeTemp", in: settings) == 0)

// MARK: ⑤ QuickLook import 在位（漏了 Archive 才炸）

check("⑤ 文件段 import QuickLook（.quickLookPreview 的框架依赖）", section.contains("import QuickLook"))
check("⑤ 文件段挂了 QuickLook 预览（.quickLookPreview($quickLookURL)）",
      section.contains(".quickLookPreview(") && section.contains("quickLookURL"))

// MARK: ⑥ 接线形态（与 form 段并列、互斥；老卡零回归）

check("⑥ AgentResultCard 有 file 段渲染分支（独立小 View）",
      card.contains("AgentCardFileSection(file: file)"))
check("⑥ 渲染与 kind 无关（靠 file != nil，别再加 .file 门控）",
      !card.contains("card.kind == .file"))
check("⑥ 文件段位置：表单段之后、页脚之前（与 form 段并列互斥）",
      orderedPair(card, after: "AgentCardFormSection(form: form", before: "AgentCardFileSection(file: file)")
      && orderedPair(card, after: "AgentCardFileSection(file: file)", before: "if let footer = card.footer"))
check("⑥ 头部图标给 file 卡留位（switch 覆盖 Kind.file，否则编译不过/图标错）",
      card.contains("case .file:"))
check("⑥ 卡片自查登录态（@Environment(AuthStore.self)，不需要跨层回调）",
      section.contains("@Environment(AuthStore.self)"))
check("⑥ 文件段类型图标与类型文案齐备（六种 kind 都有分支）",
      countOf("case .docx:", in: section) >= 1 && countOf("case .other:", in: section) >= 1)

// MARK: ⑦ 工作区产物库取数口径（v4.0.108 · dock 第 5 档「工作区」）
// 为什么值得钉：**列表能列、一点「查看」必 404** 这条本地预检与 CI 全绿（v4.0.108 审查实测）——
// 条目 path 少了 `office/` 别名根前缀时，后端 resolve_path 会回落到 uploads/ 与 ROOT，
// 下载口 os.path.isfile 失败 → 只有真机点「查看」/QuickLook 才暴露。
let ws = code(src("qingliao/Features/Workspace/WorkspaceView.swift"))
check("⑦ 工作区页源可读（空了下面几条是空真）", !ws.isEmpty)
check("⑦ 列表请求走 POST 形态（蜂窝 GET 带 query 静默挂 · v4.0.110）",
      ws.contains("auth.request(\"/api/files/list\",") && ws.contains("method: \"POST\"") && ws.contains("body: [\"path\": path]"))
check("⑦ 列表不许再用带 query 的 GET（回退即红线）",
      !ws.contains("/api/files/list?path="))
check("⑦ 条目 parent 必须带别名根前缀（fetchList 收 path；预览/下载才不 404）",
      ws.contains("RemoteFiles.parseEntries(obj?[\"entries\"], parent: path)")
      && ws.contains("private func fetchList(_ path: String) async -> FetchOutcome")
      && ws.contains("await fetchList(requestPath)") && ws.contains("await fetchList(root)"))
check("⑦ 反例：条目 parent 不许传 currentPath（缺别名前缀 → 预览 404）",
      !ws.contains("parent: currentPath"))
check("⑦ requestPath 由「当前根 + 目录」拼出（v4.0.114 起根可切换，不再是写死的 office）",
      ws.contains("atRootLevel ? \"\" : (dirStack.isEmpty ? currentRoot : currentRoot + \"/\" + currentPath)"))
check("⑦ 根层 = 两个别名根合并（office 文档 + artifacts 其它产物）",
      ws.contains("private static let artifactRoots = [\"office\", \"artifacts\"]")
      && ws.contains("for root in Self.artifactRoots {"))
check("⑦ 激活即拉产物（v4.0.110 改口径：每次激活都刷新，不再「仅空才拉」）",
      ws.contains(".task(id: isActive)")
      && ws.contains("guard isActive else { stopActivePolling(); return }")
      && ws.contains("await load(keepOnFailure: true)"))
// v4.0.110：进行中卡实时化（用户报「并没有实时显示进行中的任务」——首版只是静态入口卡）。
// 钉四件事：① 2s 轮询拉 /api/agent/tasks/active（与 TaskCenterView 同一读路径）；
// ② tab 切走 / 页面消失会停轮询；③ 卡面吃真实任务（标题 + 进度摘要 + 多任务计数），不再写死文案；
// ④ 从任务中心回来（可能刚停了任务）立刻刷新，不等下一轮。
check("⑦ 进行中卡实时轮询（2s 一轮 + 起手立即拉 + 切走即停）",
      ws.contains("Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true)")
      && ws.contains("activeTasks = await auth.fetchActiveTasks()")
      && ws.contains("startActivePolling()")
      && ws.contains(".onDisappear { stopActivePolling() }"))
check("⑦ 进行中卡吃真实任务数据（标题/detail/计数；空态才落静态文案）",
      ws.contains("if let first = activeTasks.first")
      && ws.contains("activeCardSubtitle(first)")
      && ws.contains("还有 \\(activeTasks.count - 1) 个")
      && ws.contains("暂无进行中的任务，点开看任务中心"))
check("⑦ 任务中心关闭即刷新卡面（onDismiss 立即拉一轮）",
      ws.contains("fullScreenCover(isPresented: $showTaskCenter, onDismiss:"))
// v4.0.110：卡面直接停任务（用户要求「任务卡需要有停止按钮」）。钉三件事：
// ① 停止按钮只对可停任务亮（判据与任务中心同源：kind=stream 且 running；bg 作业后端无 cancel 端点）；
// ② 确认走系统 alert（危险确认类口径，形态与 TaskCenterView 同款）；③ 停完立刻刷新卡面。
check("⑦ 进行中卡停止按钮（判据同源 + alert 确认 + 停完即刷）",
      ws.contains("first.kind == \"stream\", first.status == \"running\"")
      && ws.contains("stop.circle.fill")
      && ws.contains(".alert(\"停止这个任务？\"")
      && ws.contains("await auth.streamStop(taskId: t.id)")
      && ws.contains("@State private var stopTarget: AuthStore.ActiveTask?"))
// v4.0.110：产物列表每次激活都刷新（原「仅 entries 为空才拉」= AI 新产物永不显示的根因）；
// 静默刷新失败保留旧列表（keepOnFailure），别把用户正看到的产物顶没。
check("⑦ 产物列表激活即刷新（keepOnFailure 保旧列表）",
      ws.contains("await load(keepOnFailure: true)")
      && ws.contains("private func load(keepOnFailure: Bool = false) async")
      && !ws.contains("if entries.isEmpty { await load() }")
      // v4.0.114（审查 P2）：失败清空虚线里补了 prunePicks()，且 keepOnFailure 时
      // 不再「不清 entries 却设 failureText」（自相矛盾：列表还在、同时挂红字）。
      && ws.contains("if !keepOnFailure {\n                    failureText = firstErr\n                    entries = []\n                    prunePicks()"))
// v4.0.110：文件卡整卡可点（AI 卡文案承诺「点开卡片即可查看或下载」，原实现只有右上角
// 「查看」小按钮、点卡面没反应 = 用户报「点卡片无法查看也没法下载」）。钉：contentShape +
// onTapGesture 走同一 open()（在飞闸门在 open 内）。
let fsec = code(src("qingliao/Features/Chat/AgentCardFileSection.swift"))
check("⑦ 文件卡整卡可点（onTapGesture 同走 open）",
      fsec.contains(".contentShape(Rectangle())")
      && fsec.contains(".onTapGesture { open() }")
      && fsec.contains("guard phase != .preparing else { return }"))
// v4.0.110：解析器吃**顶层平铺**的 file 卡（AI 实测形态 `{"type":"file","path":"office/…",…}`，
// 原来只认 file 子对象 → file=nil → 卡渲染成纯结果壳、零点击入口 = 用户报「点不了」的真因）。
// 钉：回落仅 type=file；file 子对象优先；缺 path 仍 nil。
check("⑦ 解析器回落顶层平铺 file 字段（仅 type=file）",
      parser.contains("else if Kind.parse(str(dict[\"type\"]) ?? \"\") == .file {")
      && parser.contains("fd = dict")
      && parser.contains("fd = [:]")
      && parser.contains("guard !path.isEmpty else { return nil }"))
// v4.0.110：空目录/失败态也要渲染 backRow——原实现这两个分支不给返回按钮，
// 用户进空文件夹（如日期目录）就被困住（真机实报「点进去没有返回上一层按钮」）。
check("⑦ 空态/失败态分支也渲染返回上一级行",
      ws.contains("if !atRootLevel { backRow }")
      && src("qingliao/Features/Workspace/WorkspaceView.swift").contains("// v4.0.110：空目录也要给 backRow")
      && ws.components(separatedBy: "if !atRootLevel { backRow }").count - 1 >= 3)
// v4.0.109：工作区新增「待你处理」（跨会话未答问题卡；解析逻辑在 Core/WorkspacePendingKit.swift）。
// 钉住四件事：① 进页会拉待答卡；② 点卡 = 标已读 + 装会话 + 报宿主切页（三步缺一都是「点了没用」）；
// ③ 没有待答卡时那一块**不渲染**（工作区不摆空壳）；④ 长期目标整块搬来（栏目 + 页级浮层宿主同页）。
check("⑦ 待你处理：进页拉取 + 点卡标已读/装会话/报宿主切页 + 空态不占位",
      ws.contains("await loadPending()")
      && ws.contains("WorkspacePendingKit.parse(")
      && ws.contains("chat.markRead(item.sessionId, upTo: item.time)")
      && ws.contains("await chat.loadById(item.sessionId, auth: auth)")
      && ws.contains("onOpenSession?()")
      && ws.contains("if !pendingItems.isEmpty { pendingBoard.scrollDepth() }"))
check("⑦ 长期目标整块搬进工作区（栏目 + 页级浮层宿主都在本页，宿主漏挂则浮层只在卡内弹）",
      ws.contains("GoalsSection()")
      && ws.contains(".overlay { AnyView(GoalsGlassLayerHost()) }"))

// MARK: ⑧ 产物库删除（v4.0.114 · 用户「产物库内容也可以删除吧」）
// 为什么值得钉：后端 `/api/files/delete` 是**真删**（目录 rmtree / 文件 os.remove，**无回收站**）。
// 三处坏了都不报错：① 漏二次确认 → 点一下就没了；② 选择态没让位 → 点行=进目录，勾选全乱、
// 删除打空；③ 失败项没剔干净 → 红字说失败、列表里却没了，用户以为删成功。
check("⑧ 产物库单删入口（⋯ 菜单 → 确认；目录提示含内容）",
      ws.contains("Label(\"删除\", systemImage: \"trash\")")
      && ws.contains("deleteConfirmText = e.isDir ? \"删除「\\(e.name)」及其中的内容？\" : \"删除「\\(e.name)」？\"")
      && ws.contains("@ViewBuilder\n    private func rowTrailing(_ e: RemoteFileEntry)"))
check("⑧ 产物库选择态（选择/取消 + 勾选圈 + 删除(N)）",
      ws.contains("@State private var selecting = false")
      && ws.contains("@State private var picked: Set<String> = []")
      && ws.contains("Text(picked.isEmpty ? \"删除\" : \"删除(\\(picked.count))\")")
      && ws.contains("checkmark.circle.fill")
      && ws.contains("Button(selecting ? \"取消\" : \"选择\")"))
check("⑧ 选择态下左键让位（行点击 = 勾选，不进目录 / 不查看）",
      ws.contains("if selecting { togglePick(d.path); return }")
      && ws.contains(".onTapGesture { if selecting { togglePick(f.path) } }")
      && ws.contains("if !selecting {")
      // v4.0.114：点击区收到内容 HStack 内层后缩进 +4（原 16 → 现 20）
      && ws.contains("if !selecting {\n                    Image(systemName: \"chevron.right\")"))
// v4.0.114（复核 P2）：目录行的点击区收到左侧内容后，行尾那枚勾选圈掉出了命中区 ——
// 选择态点圈没反应（内容区能点、产物行整行能点，两态口径不一致）。
check("⑧ 选择态的勾选圈本身可点（拆点击区时别把行尾落在命中区外）",
      ws.contains(".onTapGesture { togglePick(e.path) }")
        && ws.contains("rowTrailing(d)")
        && ws.contains(".accessibilityAddTraits(.isButton)\n        } else {"))
check("⑧ 删除走 POST /api/files/delete（path 带别名根前缀，越界后端自会拒）",
      ws.contains("auth.json(\"/api/files/delete\", method: \"POST\", body: [\"path\": e.path])"))
check("🚫 不许无确认直删（真删无回收站）",
      ws.contains(".alert(deleteConfirmText, isPresented: $confirmDelete)")
      && ws.contains("Text(\"删除后无法恢复。\")")
      && ws.contains("deleteConfirmText = \"删除 \\(targets.count) 项？\""))
check("⑧ 删除失败不中断：成功的出列表、失败的留下列名",
      ws.contains("failed.append(e.name)")
      && ws.contains("entries.removeAll { $0.path == e.path }")
      && ws.contains("项删除失败："))
check("⑧ 回读后丢弃越目录勾选（防删到看不见的项）",
      ws.contains("private func prunePicks()")
      && ws.contains("picked = picked.intersection(Set(entries.map { $0.path }))")
      && ws.components(separatedBy: "prunePicks()").count - 1 >= 3)
check("🚫 换筛选不保留勾选（被筛掉的项还留着勾 = 打黑箱删）",
      src("qingliao/Features/Workspace/WorkspaceView.swift").contains("// v4.0.114：换筛选就清勾选")
      && ws.contains("filter = f"))

print("AI 成品文件卡真值表：#17 \(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
