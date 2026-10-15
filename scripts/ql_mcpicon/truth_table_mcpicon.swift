import Foundation

// MCP 工具服务行图标真值表（v4.0.117）
// 背景：`/api/mcp/servers` 的每一行原先把 `puzzlepiece.extension.fill` + Color.teal 写死，
// 所有 MCP 长得一模一样。现改为「后端模板自带 icon/color → 空则按服务名关键字兜底 → 拼图块」。
// 只读源码做静态断言 + 复刻匹配语义跑真实服务名（headless Linux 跑不了 SwiftUI）。

final class Counter: @unchecked Sendable {
    static let shared = Counter()
    var total = 0, failures = 0
    func check(_ label: String, _ ok: Bool) {
        total += 1
        if ok { print("✅ \(label)") } else { failures += 1; print("❌ \(label)") }
    }
}
@MainActor func check(_ label: String, _ ok: Bool) { Counter.shared.check(label, ok) }
@MainActor func report() -> Never {
    let c = Counter.shared
    print("\n———————————————")
    print(c.failures == 0 ? "✅ 全部通过 \(c.total)/\(c.total)" : "❌ 失败 \(c.failures)/\(c.total)")
    exit(c.failures == 0 ? 0 : 1)
}
func read(_ p: String) -> String {
    (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
}
/// 去掉 `//` 之后的内容再判代码 —— 注释里作为反面教材写着的坏写法不许被当代码命中。
func stripComments(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }
        .joined(separator: "\n")
}

let src = stripComments(read("qingliao/Features/Settings/SettingsAccess.swift"))

// ─────────────────────────────────────────────────────────────
// A. 后端下发的 icon/color 必须被解析进模型（否则后端白改）
// ─────────────────────────────────────────────────────────────
check("MCPServerItem 新增 icon/color 字段（带默认值）",
      src.contains("var icon: String = \"\"") && src.contains("var color: String = \"\""))

// 实参序 = 声明序：插在中间会让既有构造点编译失败（CI 才炸，本地 swiftc -parse 查不出）
let itemDecl: String = {
    guard let a = src.range(of: "struct MCPServerItem"),
          let b = src.range(of: "}", range: a.upperBound..<src.endIndex) else { return "" }
    return String(src[a.lowerBound..<b.upperBound])
}()
let iEnabled = itemDecl.range(of: "let enabled: Bool")
let iIcon = itemDecl.range(of: "var icon: String")
check("icon/color 声明序排在 enabled 之后（实参序 = 声明序，插中间会编译失败）",
      iEnabled != nil && iIcon != nil && iEnabled!.lowerBound < iIcon!.lowerBound)

check("servers 解析读 url[\"icon\"] / url[\"color\"]",
      src.contains("icon: url[\"icon\"] as? String ?? \"\"")
      && src.contains("color: url[\"color\"] as? String ?? \"\""))

check("templates 解析读 t[\"icon\"] / t[\"color\"]（后端模板带来的图标要能用上）",
      src.contains("icon: t[\"icon\"] as? String ?? \"\"")
      && src.contains("color: t[\"color\"] as? String ?? \"\""))

// ─────────────────────────────────────────────────────────────
// B. 行渲染必须真的用上，而不是继续写死
// ─────────────────────────────────────────────────────────────
check("服务行用 Image(systemName: st.icon) 渲染", src.contains("Image(systemName: st.icon)"))
check("服务行底色用 MCPRowStyle.color(st.color)",
      src.contains("MCPRowStyle.color(st.color), in: RoundedRectangle("))
check("ForEach 里算出行样式 st（id + 远端 icon/color 一起传）",
      src.contains("let st = MCPRowStyle.style(id: s.id, remoteIcon: s.icon, remoteColor: s.color)"))

// v4.0.116（发版审查 P1）：模板行原来只画 name/desc/勾选，MCPTemplate 的 icon/color 被解析进模型
// 却**没有任何渲染点** —— 典型「传了但没渲染」：同一个服务在「从模板添加」列表没图标、
// 在「已启用」列表却有。这条断言把「解析」与「渲染」绑在一起，防止再次只剩解析。
let addSheetSeg = src.components(separatedBy: "struct MCPAddSheet: View").dropFirst().first ?? ""
check("模板行也渲染 icon（MCPAddSheet 里用同一个出口，且 id 传 t.id 走同一套匹配）",
      addSheetSeg.contains("let st = MCPRowStyle.style(id: t.id, remoteIcon: t.icon, remoteColor: t.color)")
      && addSheetSeg.contains("Image(systemName: st.icon)")
      && addSheetSeg.contains("MCPRowStyle.color(st.color)"))

// 反例：写死的拼图块在整份源码里只应剩「MCPRowStyle 兜底」那一处
let hardCodedPuzzle = src.components(separatedBy: "\"puzzlepiece.extension.fill\"").count - 1
check("写死的拼图图标只剩兜底 1 处（渲染点已改用 st.icon）", hardCodedPuzzle == 1)
check("反例自证：渲染点不再有 Image(systemName: \"puzzlepiece.extension.fill\")",
      !src.contains("Image(systemName: \"puzzlepiece.extension.fill\")"))
check("行渲染不再写死 Color.teal 底（改成按行取色）",
      !src.contains(".background(Color.teal, in: RoundedRectangle("))

// ─────────────────────────────────────────────────────────────
// C. MCPRowStyle 语义
// ─────────────────────────────────────────────────────────────
check("MCPRowStyle 存在且提供 style(id:remoteIcon:remoteColor:)", src.contains("enum MCPRowStyle")
      && src.contains("static func style(id: String, remoteIcon: String, remoteColor: String) -> Row"))
// v4.0.116（发版审查 P2）：远端 icon 只认白名单 —— 非空但拼错的符号名会让 Image(systemName:)
// 渲染成一片空白色块，比落关键字兜底更糟。条件里必须**同时**带 knownRemoteIcons 校验。
check("远端 icon 优先于本地表（非空**且在白名单内**才直接返回）",
      src.contains("if !ic.isEmpty, knownRemoteIcons.contains(ic) {"))
check("白名单从关键字表派生（后端发新图标不必改两处；漏登记只会退化成兜底图标，不会空白）",
      src.contains("static let knownRemoteIcons: Set<String> = Set(table.map(\\.icon))"))

let iRemoteEarly = src.range(of: "if !ic.isEmpty, knownRemoteIcons.contains(ic) {")
let iTableLoop = src.range(of: "for r in table where")
check("优先级顺序正确：远端判空在前、本地表遍历在后",
      iRemoteEarly != nil && iTableLoop != nil && iRemoteEarly!.lowerBound < iTableLoop!.lowerBound)

check("兜底仍是拼图块 + teal（认不出的服务不许显示空白图标）",
      src.contains("return Row(keys: [], icon: \"puzzlepiece.extension.fill\", color: \"teal\")"))
check("颜色名 → Color 转换函数存在", src.contains("static func color(_ name: String) -> Color"))
check("未知颜色名回落 teal（后端给脏值也不会画不出）", src.contains("default: return .teal"))
check("颜色只认白名单名、不经 hex / 不直接 Color(远端串)（防颜色注入）",
      !src.contains("Color(hex") && !src.contains("Color(st.color)"))

// ─────────────────────────────────────────────────────────────
// D. 复刻匹配语义：拿**用户真实在用的服务名**跑一遍，断言命中且图标正确
// ─────────────────────────────────────────────────────────────
var rows: [(keys: [String], icon: String)] = []
do {
    let tableRegion: String = {
        guard let a = src.range(of: "static let table: [Row] = ["),
              let b = src.range(of: "static func style(", range: a.upperBound..<src.endIndex) else { return "" }
        return String(src[a.upperBound..<b.lowerBound])
    }()
    for seg in tableRegion.components(separatedBy: "Row(keys: [").dropFirst() {
        guard let close = seg.range(of: "]") else { continue }
        let inside = String(seg[seg.startIndex..<close.lowerBound])
        let keys = inside.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        var icon = ""
        if let r = seg.range(of: "icon: \"") {
            let rest = seg[r.upperBound...]
            if let end = rest.range(of: "\"") { icon = String(rest[rest.startIndex..<end.lowerBound]) }
        }
        rows.append((keys, icon))
    }
}
check("关键字表解析出 \(rows.count) 行（表被拆散/写法变了会让后续断言全红）", rows.count >= 8)
check("表里没有过短关键字 \"ha\"（会误命中 chat / whatsapp 之类）",
      !src.contains("keys: [\"ha\"") && !src.contains("\"ha\",") && !src.contains(", \"ha\""))
check("表里没有裸 \"map\" 关键字（会误命中 imap）",
      !src.contains("keys: [\"map\"") && !src.contains("\"map\","))

/// 复刻生产语义：小写化后按表顺序取第一个「服务名包含该关键字」的行
/// ⚠️ 必须标 @MainActor：Swift 6 严格并发下顶层 `rows` 属于 main actor，
/// 非隔离的自由函数读它会直接编译失败（真值表自己先炸）。
@MainActor func resolve(_ id: String) -> String {
    let k = id.lowercased()
    for r in rows where r.keys.contains(where: { k.contains($0) }) { return r.icon }
    return "puzzlepiece.extension.fill"
}

// 用户 NAS 上实际注册的 5 个 MCP（截图/接口实测：browser-agent / luckin / office / wenyan / xunlei-download）
check("browser-agent → safari.fill", resolve("browser-agent") == "safari.fill")
check("luckin → mug.fill", resolve("luckin") == "mug.fill")
check("office → doc.text.fill", resolve("office") == "doc.text.fill")
check("wenyan → doc.richtext.fill", resolve("wenyan") == "doc.richtext.fill")
check("xunlei-download → arrow.down.circle.fill", resolve("xunlei-download") == "arrow.down.circle.fill")
check("amap（后端模板同名的服务）→ map.fill", resolve("amap") == "map.fill")
check("不认识的服务名 → 拼图块兜底（不空白、不崩）",
      resolve("some-unknown-mcp") == "puzzlepiece.extension.fill")
check("匹配大小写不敏感（用户可能填 Office / LUCKIN）",
      resolve("Office") == "doc.text.fill" && resolve("LUCKIN") == "mug.fill")
check("反例自证：不存在的关键字不产生误命中", resolve("zzz-nothing") == "puzzlepiece.extension.fill")

// 反例：MCP 行图标不许与「记账分类特有符号」重合。
// 那份映射的单真源在 Core/RecordKit.swift，ql_record 的「只许出现在 RecordKit」护栏
// 会扫全仓 —— 这里复用会让那条红（2026-10-15 实踩：瑞幸用了 cup.and.saucer.fill）。
let recordSpecSymbols = ["cup.and.saucer.fill", "ticket.fill", "basket.fill",
                         "cross.case.fill", "gamecontroller.fill", "gift.fill"]
check("MCP 图标不与记账分类特有符号重合（否则与 ql_record 护栏打架）",
      !recordSpecSymbols.contains { src.contains("\"\($0)\"") })

report()
