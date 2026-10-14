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
check("⑦ 列表请求走别名根 requestPath", ws.contains("RemoteFiles.queryEncoded(requestPath)"))
check("⑦ 条目 parent 传 requestPath（带别名前缀，预览/下载才不 404）",
      ws.contains("RemoteFiles.parseEntries(obj?[\"entries\"], parent: requestPath)"))
check("⑦ 反例：条目 parent 不许传 currentPath（缺别名前缀 → 预览 404）",
      !ws.contains("parent: currentPath"))
check("⑦ requestPath 由别名根拼出（office/ + 当前目录）",
      ws.contains("Self.artifactRoot + \"/\" + currentPath"))
check("⑦ 只在激活时拉产物（不给 TabView 预建白跑请求）",
      ws.contains(".task(id: isActive)") && ws.contains("isActive && entries.isEmpty"))

print("AI 成品文件卡真值表：#17 \(passCount) 通过 / \(failCount) 失败")
exit(failCount == 0 ? 0 : 1)
