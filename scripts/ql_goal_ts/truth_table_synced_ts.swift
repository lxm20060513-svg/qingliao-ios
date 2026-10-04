// MARK: - SyncedStore 宽松 ISO8601 真值表（2026-10-04 实障）
//
// 用户原话：*「1.4.0.45版本待办清单还是没有自己划已经完成的项目」*
//          *「长期目标卡片没有跟任务中心步骤对应起来，任务中心目前是4/9，目标卡片还是只划了1和2」*
//
// 根因：goals.json / todos.json 有**两个写入方**。后端（goal_module、goals_api、
//   proactive_agent）用 `datetime.now().isoformat()` 回写 → 容器 TZ=UTC → 落盘是
//   `2026-10-04T09:59:58.666916`（naive + 微秒）。iOS 端 SyncedStore 用 JSONDecoder
//   `.iso8601` 解码，只认「带时区 + 无小数秒」→ **整个数组 dataCorrupted** → 被 decode 的
//   `try?` 吞掉 → loadFromServer 静默 return → 界面永远停在本地旧快照：后端已划掉的
//   4 条待办不显示、目标步骤 ③④ 不勾（任务中心 4/9 而卡片只有 1、2）。
//
// 本表钉住三件事：
//   ① 镜像：宽松解析口径（5 种可解形态 + 拒绝垃圾串 + **naive 按 UTC 解释**的语义）
//   ② iOS 接线：SyncedStore 解码不再用裸 `.iso8601`（防回退到旧写法）
//   ③ 真实数据 + 后端源码：NAS 上现存 5 个 SyncedStore 文件的每个时间戳都能解开，
//      且 goals/todos 必须是 `…Z` 形态、后端源码不得再出现 naive 写法
//      （后端若再写坏格式，这条直接红 —— 本机没挂载 NAS 时自动跳过并明确说明）

import Foundation

var pass = 0, fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo: String = {
    if let e = ProcessInfo.processInfo.environment["QL_REPO"], !e.isEmpty { return e }
    // #filePath = <repo>/scripts/ql_*/truth_table_*.swift → 上溯三级到仓库根
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}()
func read(_ rel: String) -> String {
    (try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8)) ?? ""
}
/// 去注释：注释里提到旧口径不算数（防「改了代码但注释还对」的假通过）
func code(_ rel: String) -> String {
    read(rel).split(separator: "\n").map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}

// ── ① 镜像：与 SyncedStore.parseISO 同口径（formatter 配置逐字对齐） ──
let fracFmt = ISO8601DateFormatter()
fracFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let plainFmt = ISO8601DateFormatter()
plainFmt.formatOptions = [.withInternetDateTime]
let naiveFmt = DateFormatter()
naiveFmt.locale = Locale(identifier: "en_US_POSIX")
naiveFmt.timeZone = TimeZone(identifier: "UTC")
naiveFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

func looseParse(_ s: String) -> Date? {
    if let d = fracFmt.date(from: s) { return d }
    if let d = plainFmt.date(from: s) { return d }
    // v4.0.46 补链（审查抓到）：带显式偏移却落到这里（6 位小数不被上面两个 formatter 认）→
    //   naive 兜底是按 UTC 解释的，硬解会把 `17:59:58+08:00` 变成 `17:59:58Z`（差 8 小时）→ 宁可 nil。
    if !s.hasSuffix("Z"), !s.hasSuffix("z"),
       s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil { return nil }
    let head = s.split(separator: ".").first.map(String.init) ?? s
    return naiveFmt.date(from: head)
}
/// 严格形态（= 原 `.iso8601` 解码策略所认的形态）：带时区 + 无小数秒
func strictParse(_ s: String) -> Date? { plainFmt.date(from: s) }

print("── ① 镜像：宽松解析口径 ──")
let appForm = "2026-10-04T03:14:51Z"                  // App 写出/后端修好后的形态
let beNaiveFrac = "2026-10-04T09:59:58.666916"        // 后端历史真实值（本次实障元凶）
let beNaive = "2026-10-04T09:59:58"
let withFrac = "2026-10-04T09:59:58.666Z"
let offset = "2026-10-04T17:59:58+08:00"

ok(looseParse(appForm) != nil, "App 形态 `…Z` 可解")
ok(looseParse(beNaiveFrac) != nil, "后端历史形态 naive+微秒 可解（关键：严格解析解不开）")
ok(looseParse(beNaive) != nil, "无时区无微秒 可解")
ok(looseParse(withFrac) != nil, "带小数秒 + Z 可解")
if let a = looseParse(withFrac), let b = looseParse("2026-10-04T09:59:58Z") {
    ok(abs(a.timeIntervalSince(b) - 0.666) < 0.001,
       "语义：带小数秒 + Z 保留毫秒精度（与整秒相差 0.666s）")
} else { ok(false, "语义：带小数秒 + Z 保留毫秒精度") }
ok(looseParse(offset) != nil, "带时区偏移 可解")
// v4.0.46 补链（审查抓到的可达性洞）：带偏移 **且** 6 位小数 → 两个 ISO8601 formatter 都不认，
//   若不拦，naive 会把 `17:59:58+08:00` 当 UTC 解成 `17:59:58Z` —— 真值差 8 小时（比解不开更坏）。
// 实测（swift-corelibs-foundation）：frac formatter 能**正确**解这种串（= 09:59:58.666Z，不是差 8 小时）；
//   护栏（带偏移却两个 formatter 都不认 → nil）的意义是兜底：要么解对，要么判不认识，绝不许 naive 按 UTC 硬解。
if let d = looseParse("2026-10-04T17:59:58.666916+08:00") {
    let utc = looseParse("2026-10-04T09:59:58Z")!
    ok(abs(d.timeIntervalSince(utc)) < 1.0,
       "带偏移 + 6 位小数 若可解 → 必须解出**正确**时刻（= 09:59:58Z）；差 8 小时即红")
} else {
    ok(true, "带偏移 + 6 位小数 → 判为不认识（护栏生效；绝不许按 UTC 硬解出差 8 小时）")
}
ok(looseParse("2026-10-04T09:59:58.666916Z") != nil,
   "对照：带 Z + 6 位小数 仍可解（Z 就是 UTC，naive 兜底没错，只丢亚秒）")
if let a = looseParse("2026-10-04T09:59:58.666916Z"), let b = looseParse("2026-10-04T09:59:58Z") {
    ok(abs(a.timeIntervalSince(b)) < 1.0, "带 Z 的亚秒被截掉，但整体时刻不变（同一秒）")
} else { ok(false, "带 Z 的亚秒被截掉，但整体时刻不变（同一秒）") }
ok(looseParse("不是时间") == nil, "垃圾串返回 nil（不假装解出来）")
ok(looseParse("") == nil, "空串返回 nil")

ok(strictParse(beNaiveFrac) == nil && strictParse(beNaive) == nil,
   "口径记录：naive/微秒形态在严格 .iso8601 下**必然失败**（这就是当初整个文件解不开的原因）")

ok(looseParse(beNaive) == looseParse("2026-10-04T09:59:58Z"),
   "语义：无时区按 **UTC** 解释（= 容器 TZ=UTC 的写法，不 +8h）")
ok(looseParse(beNaiveFrac) == looseParse("2026-10-04T09:59:58Z"),
   "语义：小数秒截断后与整秒同一时刻（展示无影响）")
ok(looseParse(offset) == looseParse("2026-10-04T09:59:58Z"),
   "+08:00 与 UTC 同一时刻（时区换算正确）")

// 真实解码路径：Decodable 结构体 + .custom 策略（与 makeDecoder 同构）
print("── ①b 镜像：整条解码链路（custom 策略 + Date 字段）──")
struct Probe: Decodable { let at: Date }
func decodeOne(_ s: String) -> Date? {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { dec in
        let c = try dec.singleValueContainer()
        let str = try c.decode(String.self)
        guard let date = looseParse(str) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法解析的时间戳：\(str)")
        }
        return date
    }
    let json = "{\"at\":\"\(s)\"}".data(using: .utf8)!
    return (try? d.decode(Probe.self, from: json))?.at
}
ok(decodeOne(beNaiveFrac) != nil, "结构体解码：后端历史值不再抛 dataCorrupted")
ok(decodeOne(appForm)?.timeIntervalSince1970 == decodeOne(withFrac)?.timeIntervalSince1970
   || decodeOne(appForm) != nil, "结构体解码：App 形态照常可解")
ok(decodeOne("坏值") == nil, "结构体解码：真坏值仍抛错（不静默变成 1970）")

// ── ② iOS 接线：SyncedStore 不再用裸 .iso8601 解码 ──
print("── ② iOS 接线（SyncedStore.swift）──")
let synced = code("qingliao/Core/SyncedStore.swift")
ok(!synced.contains("dateDecodingStrategy = .iso8601"),
   "解码策略不再是裸 .iso8601（回退即红）")
ok(synced.contains("dateDecodingStrategy = .custom"),
   "解码走 .custom（宽松解析）")
ok(synced.contains("withFractionalSeconds"),
   "显式接受带小数秒的形态")
ok(synced.contains("TimeZone(identifier: \"UTC\")"),
   "无时区形态按 UTC 解释（与后端写入端同口径）")
ok(synced.contains("dateEncodingStrategy = .iso8601"),
   "编码仍是 .iso8601（App 写出的 `…Z` 不变，后端 fromisoformat 照常解析）")
// 5 个 Store 都走同一个底座（任一 Store 自己 new JSONDecoder 就会绕过本修）
let stores = ["PinStore", "MemoStore", "TodoStore", "RecordStore", "GoalStore"]
for s in stores {
    let src = code("qingliao/Core/\(s).swift")
    if src.isEmpty { continue }
    ok(!src.contains("JSONDecoder()"),
       "\(s) 不自己造 JSONDecoder（统一走 SyncedStore.makeDecoder）")
}

// ── ③ 真实数据 + 后端源码（本机挂载 NAS 时检查）──
print("── ③ 真实数据 / 后端写入端 ──")
let dataDir = "/opt/hermes_host/微信文件/轻聊web/data"
let backendDir = "/opt/hermes_host/微信文件/轻聊web/backend"
let fm = FileManager.default
let mirrorOK = fm.fileExists(atPath: dataDir)

if !mirrorOK {
    print("  ⏭  本机没挂载 NAS（\(dataDir) 不存在）→ 跳过真实数据检查")
} else {
    let dateish = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}T")
    func scan(_ o: Any, _ path: String, _ loose: inout [String], _ bad: inout [String], _ strictBad: inout [String]) {
        if let d = o as? [String: Any] {
            for (k, v) in d { scan(v, path + "." + k, &loose, &bad, &strictBad) }
        } else if let a = o as? [Any] {
            for (i, v) in a.enumerated() { scan(v, path + "[\(i)]", &loose, &bad, &strictBad) }
        } else if let s = o as? String {
            let r = NSRange(s.startIndex..<s.endIndex, in: s)
            guard dateish.firstMatch(in: s, range: r) != nil else { return }
            if looseParse(s) == nil { bad.append("\(path)=\(s)") }
            if strictParse(s) == nil { strictBad.append("\(path)=\(s)") }
            loose.append("\(path)=\(s)")
        }
    }
    let files = ["goals.json", "todos.json", "memos.json", "records.json", "pins.json"]
    for f in files {
        let p = dataDir + "/" + f
        guard let raw = fm.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: raw) else { continue }
        var looseAll: [String] = [], bad: [String] = [], strictBad: [String] = []
        scan(obj, f, &looseAll, &bad, &strictBad)
        if looseAll.isEmpty { continue }
        ok(bad.isEmpty, "\(f)：\(looseAll.count) 个时间戳全部可解（宽松路径）")
        if !bad.isEmpty { for b in bad.prefix(5) { print("      ↳ 解不开：\(b)") } }
        // 后端契约：goals/todos 由后端回写 → 必须是严格形态，App 用旧包也能读
        if f == "goals.json" || f == "todos.json" {
            ok(strictBad.isEmpty,
               "\(f)：全部为 `…Z` 严格形态（旧 App 包也能解 → 后端不得再写 naive/微秒）")
            if !strictBad.isEmpty { for b in strictBad.prefix(5) { print("      ↳ 非严格形态：\(b)") } }
        }
    }
    // 后端源码：不得再出现 naive 时间戳写法
    let beFiles = ["goal_module.py", "goals_api.py", "proactive_agent.py"]
    var beFound = 0
    for bf in beFiles {
        let src = (try? String(contentsOfFile: backendDir + "/" + bf, encoding: .utf8)) ?? ""
        if src.isEmpty { continue }
        beFound += 1
        let body = src.split(separator: "\n").map { line -> String in
            guard let r = line.range(of: "#") else { return String(line) }
            return String(line[line.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
        // 只看**真写入调用**形态（docstring/注释里提到旧写法不算 —— 那是解释，不是代码）
        let naiveWrites = ["= datetime.now().isoformat()", "= _now().isoformat()",
                           "{\"at\": _now().isoformat()"]
        ok(!naiveWrites.contains(where: { body.contains($0) }),
           "后端 \(bf) 不再用 naive `.isoformat()` 写 SyncedStore 文件")
        ok(body.contains("_iso_now()"), "后端 \(bf) 用了 _iso_now()（UTC+Z 统一口径）")
    }
    if beFound == 0 { print("  ⏭  未找到后端源码（\(backendDir)）→ 跳过后端源码检查") }
}

print("\n通过 \(pass) 项，失败 \(fail) 项")
exit(fail == 0 ? 0 : 1)
