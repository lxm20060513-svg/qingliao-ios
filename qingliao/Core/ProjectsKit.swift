import Foundation

// v4.0.143 · 工作台「进行项目」数据层
//
// 数据源：后端 GET /api/agent/projects（projects_api.py 只读下发）
// 上游：Hermes 侧采集器 /opt/data/scripts/qingliao_projects/collect.py
//   → 读 git / 版本文件 / 本批清单 → POST /api/agent/projects/sync → projects.json
//
// 口径（与方案图一致，别改）：
//   · 进度只认后端给的 batch.done/total；没有清单就**不画进度条**，只显示「N 项待做」
//   · 版本号/最近更新全部是机器取的真值，客户端不做任何推算或补全
//   · generatedAt 超过 6 小时 → 卡面标「数据可能过期」，不让旧快照冒充实时

struct QLProjectRelease: Identifiable, Hashable {
    let version: String
    let at: Int
    let note: String
    var id: String { version + "|\(at)" }
}

struct QLProjectCommit: Identifiable, Hashable {
    let at: Int
    let text: String
    var id: String { "\(at)|\(text)" }
}

struct QLProjectBatchItem: Identifiable, Hashable {
    let title: String
    let done: Bool
    var id: String { title }
}

struct QLProject: Identifiable, Hashable {
    let slug: String
    let name: String
    let icon: String
    let colorHex: String
    let status: String
    let note: String
    let version: String
    let build: String
    let repo: String
    let branch: String
    let dirtyCount: Int
    let running: Bool
    let batchTitle: String
    let batchItems: [QLProjectBatchItem]
    let done: Int
    let total: Int
    let nextStep: String
    let lastCommitAt: Int
    let lastCommitText: String
    let recentCommits: [QLProjectCommit]
    let recentReleases: [QLProjectRelease]

    var id: String { slug }

    /// 有清单才画进度条 —— 没清单的百分比一律是编的
    var hasProgress: Bool { total > 0 }

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// 版本显示：v4.0.143 (699) —— build 缺省只显示版本
    var versionText: String {
        if version.isEmpty { return "—" }
        let v = version.hasPrefix("v") ? version : "v" + version
        return build.isEmpty ? v : "\(v) (\(build))"
    }

    static func parse(_ d: [String: Any]) -> QLProject? {
        guard let slug = d["slug"] as? String, !slug.isEmpty,
              let name = d["name"] as? String else { return nil }
        let batch = d["batch"] as? [String: Any] ?? [:]
        let items = (batch["items"] as? [[String: Any]] ?? []).compactMap { it -> QLProjectBatchItem? in
            guard let t = it["t"] as? String else { return nil }
            return QLProjectBatchItem(title: t, done: it["done"] as? Bool ?? false)
        }
        let commits = (d["recentCommits"] as? [[String: Any]] ?? []).compactMap { c -> QLProjectCommit? in
            guard let t = c["text"] as? String else { return nil }
            return QLProjectCommit(at: c["at"] as? Int ?? 0, text: t)
        }
        let releases = (d["recentReleases"] as? [[String: Any]] ?? []).compactMap { r -> QLProjectRelease? in
            guard let v = r["version"] as? String else { return nil }
            return QLProjectRelease(version: v, at: r["at"] as? Int ?? 0, note: r["note"] as? String ?? "")
        }
        return QLProject(
            slug: slug,
            name: name,
            icon: d["icon"] as? String ?? String(name.prefix(1)),
            colorHex: d["color"] as? String ?? "#5B6CFF",
            status: d["status"] as? String ?? "",
            note: d["note"] as? String ?? "",
            version: d["version"] as? String ?? "",
            build: d["build"] as? String ?? "",
            repo: d["repo"] as? String ?? "",
            branch: d["branch"] as? String ?? "",
            dirtyCount: d["dirtyCount"] as? Int ?? 0,
            running: d["running"] as? Bool ?? false,
            batchTitle: batch["title"] as? String ?? "",
            batchItems: items,
            done: batch["done"] as? Int ?? 0,
            total: batch["total"] as? Int ?? 0,
            nextStep: d["nextStep"] as? String ?? "",
            lastCommitAt: d["lastCommitAt"] as? Int ?? 0,
            lastCommitText: d["lastCommitText"] as? String ?? "",
            recentCommits: commits,
            recentReleases: releases
        )
    }
}

extension AuthStore {
    /// 项目列表（工作台「进行项目」卡）。
    /// 失败静默返回 nil —— 调用方保留旧列表，不把网络抖动显示成「一个项目都没有」。
    func fetchProjects() async -> (projects: [QLProject], generatedAt: Int)? {
        guard let d = await jsonOrLog("/api/agent/projects"),
              let arr = d["projects"] as? [[String: Any]] else { return nil }
        return (arr.compactMap { QLProject.parse($0) }, d["generatedAt"] as? Int ?? 0)
    }
}

/// 相对时间（10 秒前 / 12 分钟前 / 3 小时前 / 2 天前）——全站口径统一，别各处自己写
enum ProjectTime {
    static func ago(_ ts: Int) -> String {
        guard ts > 0 else { return "—" }
        let d = Int(Date().timeIntervalSince1970) - ts
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(d / 60) 分钟前" }
        if d < 86400 { return "\(d / 3600) 小时前" }
        return "\(d / 86400) 天前"
    }

    static let staleAfter = 6 * 3600
}
