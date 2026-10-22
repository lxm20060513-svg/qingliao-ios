import Foundation

// v4.0.149 · 工作台「进行项目」详情页：清单整块的「滑掉」状态
//
// 口径（用户 2026-10-22：「如果是已经完成的、已经滑掉的就不用显示了」）：
//   · 详情页左滑「清单」卡 → 整块收起，只留进度 / 最近更新 / 版本历史；
//   · 收起按项目 slug 记一份**本批指纹**：台账换了新批次（条目或勾选变了）→ 指纹不匹配 →
//     清单自动重新出现。用户收起的是「这一批」，不是「以后永远别看清单」。
//   · 🚨 指纹必须跨启动稳定：用 djb2。**不能**用 Swift 对 String 的默认哈希
//     —— 每个进程随机加盐，重启后收起状态时灵时不灵，是最难查的那类 bug。
//
// 纯 Foundation、不依赖 QLProject：本文件能在 Linux 上单文件编译做真值表
// （/opt/data/qingliao_ios/scripts/ql_projects/test_batch_dismissal.swift）。

struct ProjectBatchDismissal {
    /// AppStorage key 的单一真源（视图侧只引用这个常量，不写字面量 —— 两处写死迟早改漏一处）
    static let storageKey = "workspace_projects_hidden_batch"

    /// 清单条目（只留判定需要的两个字段 → 本文件可脱离 App 模型单独编译）
    struct Entry: Hashable {
        let title: String
        let done: Bool

        init(title: String, done: Bool) {
            self.title = title
            self.done = done
        }
    }

    /// 本批指纹（djb2，顺序敏感、跨进程稳定）
    static func fingerprint(_ items: [Entry]) -> String {
        var h: UInt64 = 5381
        for it in items {
            for byte in "\(it.title)|\(it.done ? 1 : 0);".utf8 {
                h = (h &* 33) &+ UInt64(byte)
            }
        }
        return String(h, radix: 16)
    }

    /// 解析成 [slug: 指纹]；脏数据（没有冒号 / 空 slug / 空指纹）直接丢，
    /// 不让一条坏记录把整串读成空（否则所有项目的收起状态一起消失）
    static func map(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let slug = String(parts[0])
            let fp = String(parts[1])
            guard !slug.isEmpty, !fp.isEmpty else { continue }
            out[slug] = fp
        }
        return out
    }

    /// 串行化：键排序后拼接 —— 同一份集合永远得到同一串，AppStorage 不会因为写入顺序不同反复改写
    static func serialize(_ map: [String: String]) -> String {
        map.keys.sorted().compactMap { key -> String? in
            guard let fp = map[key], !fp.isEmpty else { return nil }
            return "\(key):\(fp)"
        }.joined(separator: ",")
    }

    /// 当前这批是否已被收起：**指纹相同才算收起**（换批次自动重新显示）
    static func isHidden(_ raw: String, slug: String, fingerprint: String) -> Bool {
        guard !slug.isEmpty, !fingerprint.isEmpty else { return false }
        return map(raw)[slug] == fingerprint
    }

    /// 收起这批：写入 / 覆盖该项目的一条记录，其余项目原样保留
    static func hiding(_ raw: String, slug: String, fingerprint: String) -> String {
        guard !slug.isEmpty, !fingerprint.isEmpty else { return raw }
        var m = map(raw)
        m[slug] = fingerprint
        return serialize(m)
    }

    /// 撤销：只删这个项目那一条，不动别的项目
    static func showing(_ raw: String, slug: String) -> String {
        var m = map(raw)
        m.removeValue(forKey: slug)
        return serialize(m)
    }
}
