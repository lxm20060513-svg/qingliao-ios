import Foundation

// MARK: - v3.9.32 文件管理（NAS 上传目录浏览）纯逻辑层
//
// 为什么单独一个文件：本文件**只依赖 Foundation**，不 import SwiftUI/UIKit —— 本机（无 Xcode SDK）
// 能用 swiftc 真编译 + 真跑一份真值表（scripts/ql_files/truth_table_files.swift），把「JSON 解析 /
// 排序 / 体积格式 / 路径拼接 / 扩展名分流」这些纯函数在推 CI 前就验掉。
// 视图层（Features/Settings/FilesManagerSheet.swift）只做渲染与调用，不再夹带解析逻辑。
//
// ── 后端契约（NAS files_api.py，2026-09-17 只读核实；/api/files 经 unified_router 9127 转发）──
//   GET  /api/files/config               → {"ok":true,"upload_dir":"<绝对路径>"}                （需鉴权）
//   GET  /api/files/list?path=<相对路径>  → {"cwd":"<相对 data/ 根>","entries":[
//                                            {"name":"x.jpg","is_dir":false,"size":760776,"mtime":1788961589}],
//                                          "dir_count":N,"file_count":M}                        （需鉴权）
//   GET  /api/files/download?path=<相对>  → 原始字节（Content-Disposition: attachment；
//                                           **上传目录内文件匿名可读**，无需 token；隐藏/密钥类 403）
//   POST /api/files/delete               → {"path":"<相对>"} → {"ok":true} / {"error":"…"}
//                                          ⚠️ 传目录会 rmtree 递归删除
//   POST /api/files/rename               → {"path":"<相对>","new_name":"新名"} → {"ok":true}
//                                          / {"error":"同名文件已存在"}（new_name 含 "/" 或为 . / .. → 400）
//
// path 一律是**相对上传目录**（后端 resolve_path 先按上传目录解析，命中即用），空串 = 上传目录根。
// ⚠️ 后端的 list.cwd 是相对 data/ 根计算的（上传目录在 data 之外 → 根目录返回 "../uploads"），
//    所以面包屑由客户端自己维护，**不要直接显示服务端 cwd**。

/// 上传目录里的一个条目（/api/files/list 的 entries 项 + 客户端拼出的相对路径）
struct RemoteFileEntry: Identifiable, Hashable {
    /// 展示名 / 磁盘上的 basename
    let name: String
    /// 相对上传目录的路径（list / download / delete / rename 的 path 参数用它）
    let path: String
    /// 是否目录（后端 is_dir）
    let isDir: Bool
    /// 字节数（目录恒 0）
    let size: Int
    /// 修改时间（Unix 秒；后端 mtime）
    let mtime: Int

    var id: String { path }
}

/// 打开方式分流
enum FilePreviewKind: Equatable {
    /// App 内图片查看器（ImageViewer）
    case image
    /// 快速查看（QuickLook，需先下载到本地临时目录）
    case quickLook
    /// 不预览，只能分享/下载
    case unsupported
}

enum RemoteFiles {

    // MARK: 常量

    /// 蜂窝网络下的下载上限：超过此体积不再尝试（relay 上下行受限，硬试只会留下"点了没反应"）
    static let cellularSafeBytes = 4 * 1024 * 1024

    /// 图片（走 App 内查看器）
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "tiff", "ico"]

    /// 文本/文档（走 QuickLook：只吃本地文件，调用方必须先下载落盘）
    static let quickLookExts: Set<String> = ["pdf", "md", "csv", "txt", "json", "log"]

    // MARK: 解析

    /// 取扩展名（小写，不含点）
    static func ext(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// 打开方式：图片 → 查看器；pdf/md/csv/txt/json/log → QuickLook；其余 → 不支持预览
    static func previewKind(forName name: String) -> FilePreviewKind {
        let e = ext(name)
        if imageExts.contains(e) { return .image }
        if quickLookExts.contains(e) { return .quickLook }
        return .unsupported
    }

    /// 子条目相对路径（parent 为空 = 上传目录根）
    static func childPath(parent: String, name: String) -> String {
        let p = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if p.isEmpty { return name }
        return p + "/" + name
    }

    /// 上一级相对路径（根返回空串）
    static func parentPath(_ path: String) -> String {
        let parts = path.split(separator: "/").map { String($0) }
        return parts.dropLast().joined(separator: "/")
    }

    /// 路径参数的百分号编码：`&` `#` `+` `=` `?` `/` 都必须编掉，否则带这些字符的文件名会被
    /// parse_qs 拆成多个参数（.urlQueryAllowed 恰恰不编这些字符，不能直接用）
    static func queryEncoded(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "?&=+#;/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 落本地临时目录时用的安全文件名（防后端下发的名字带路径分隔符写到别处）
    /// ⚠️ 不要用 `(name as NSString).lastPathComponent`：**Linux 上 Foundation 把 ":" 也当路径分隔符**
    ///（"a/b:c.jpg" → "b:c.jpg"），与 iOS 行为不一致、本地真值表会假红/假绿。这里显式只按 "/" 切。
    static func safeLocalName(_ name: String) -> String {
        let base = name.components(separatedBy: "/").last ?? name
        let cleaned = base
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "qingliao_file.dat" }
        return String(cleaned.prefix(120))
    }

    /// JSON 数字 → Int：**必须**防 NaN/Inf/超范围（`Int(Double.nan)` 是 trap 不是 nil，脏数据能把 App 打崩）
    static func intValue(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let d = raw as? Double {
            guard d.isFinite, d > -9.0e15, d < 9.0e15 else { return 0 }
            return Int(d)
        }
        if let n = raw as? NSNumber {
            let d = n.doubleValue
            guard d.isFinite, d > -9.0e15, d < 9.0e15 else { return 0 }
            return Int(d)
        }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }

    static func stringValue(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return ""
    }

    /// 解析 list 响应的 entries（容错：缺字段/脏数据跳过而不是整体失败）
    static func parseEntries(_ raw: Any?, parent: String) -> [RemoteFileEntry] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        var out: [RemoteFileEntry] = []
        for item in arr {
            let name = stringValue(item["name"])
            guard !name.isEmpty else { continue }
            let isDir = (item["is_dir"] as? Bool) ?? false
            out.append(RemoteFileEntry(name: name,
                                       path: childPath(parent: parent, name: name),
                                       isDir: isDir,
                                       size: isDir ? 0 : intValue(item["size"]),
                                       mtime: intValue(item["mtime"])))
        }
        return sorted(out)
    }

    /// 排序：目录在前（名称升序），文件按修改时间**倒序**（新传的排最上），时间相同按名称升序
    static func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            if a.isDir { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            if a.mtime != b.mtime { return a.mtime > b.mtime }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: 展示

    /// 人类可读体积（与后端 files_api.human_size 同口径）
    static func humanSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        var n = Double(bytes) / 1024
        for unit in ["KB", "MB", "GB"] {
            if n < 1024 || unit == "GB" { return String(format: "%.1f %@", n, unit) }
            n /= 1024
        }
        return "\(bytes) B"
    }

    /// 修改时间文本（本地时区；脏值给占位而不是 1970 或崩）
    static func modifiedText(_ ts: Int) -> String {
        guard ts > 0 else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// 计数文本（list 响应的 dir_count / file_count）
    static func countText(dir: Int, file: Int) -> String {
        if dir == 0 && file == 0 { return "空目录" }
        if dir == 0 { return "\(file) 个文件" }
        if file == 0 { return "\(dir) 个文件夹" }
        return "\(dir) 个文件夹 · \(file) 个文件"
    }

    /// 蜂窝网络下该体积能否下载
    static func cellularDownloadAllowed(bytes: Int) -> Bool {
        // SR11：名字里的"蜂窝"原来没实现——这里无条件按 `bytes <= 4MB` 判定，
        // 于是 **WiFi 下超过 4MB 的文件也走这条闸门**，弹出的提示还是「请连接 WiFi 后重试」，
        // 用户已在 WiFi、照做也永远解不开（预览/分享两条路径全被挡）。闸门只在真蜂窝时生效。
        guard NetworkMonitor.shared.isCellular else { return true }
        return bytes <= cellularSafeBytes
    }
}
