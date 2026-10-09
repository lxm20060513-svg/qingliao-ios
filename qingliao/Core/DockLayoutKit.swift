import Foundation

/// v4.0.82（2026-10-09 用户口径）：「设置里面增加 dock 栏设置，聊天、生活、看板、设置页可以调整顺序，
/// 可以隐藏某一页，唯独设置页不能隐藏」。
///
/// 为什么是最小纯逻辑 + 字符串层（而不是拿 `DockTab` 枚举来做）：
///   · `DockTab` 定义在 `Features/DockTabView.swift`（import SwiftUI）→ 真值表一旦引用它就必须连 SwiftUI 一起编，
///     在 Linux 工具链上编不过（本仓规矩：真值表只编纯源码）。所以这里**只认 rawValue 字符串**，
///     视图侧做 `DockTab(rawValue:)` 映射（映射的合法性由表里的源码断言钉住）。
///   · 视图（DockTabView / DockLayoutSheet）只做两件事：读这里的结论 + 把用户操作写回原始串。
///
/// ⚠️ 两条硬口径（都来自用户原话，别在视图里另写一套判断 —— 单一真源就在本文件）：
///   ① 设置页**永远不可隐藏**：闸门只有 `canHide(raw:)` 一处。
///   ② 顺序可任意调整（4 档全可动）：坏串一律回出厂序（宁可回默认，也不许让 dock 悄悄少一格）。
///
/// ⚠️ 历史备忘：v4.0.70 做过一版「Dock 顺序自定义」，那是**5 槽（智慧球恒留第 3 槽）**时代的形态，
///    顺序串里不含球、球心几何按 `slotIndex: 2` 硬编码；该批随 v4.0.72 整块回退（DockTabView -441 行）。
///    v4.0.81 起 dock 缩成 4 档、球已移出 dock（只由长按宠物调用）→ 没有「球必须居中」的约束了，
///    4 档可以真正任意排，当初那套「球不许离开 index 2」的限制不要再照搬过来。
enum DockLayoutKit {

    /// 可入 dock 的 4 档 rawValue（出厂序）。
    /// ⚠️ 必须与 `DockTab` 的 rawValue 一致（表里有源码断言钉住）。
    static let allRaw: [String] = ["chat", "life", "dashboard", "settings"]

    /// 出厂顺序串（`@AppStorage` 的初始值）
    static let defaultOrderRaw = "chat,life,dashboard,settings"

    /// 唯一不可隐藏的一档（用户口径①）
    static let unHidableRaw = "settings"

    /// 这一档能不能隐藏？—— 唯一闸门（UI 的开关禁用态与渲染侧的过滤都走它）
    static func canHide(raw: String) -> Bool { raw != unHidableRaw }

    /// 顺序串 → 合法顺序：未知项剔除、去重、缺的按出厂序补到末尾；结果不完整（≠4 档）→ 整体回出厂序。
    static func sanitizedOrder(_ raw: String) -> [String] {
        let parsed = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for r in parsed where allRaw.contains(r) && !out.contains(r) { out.append(r) }
        for r in allRaw where !out.contains(r) { out.append(r) }
        return out == allRaw || (out.count == allRaw.count && Set(out) == Set(allRaw)) ? out : allRaw
    }

    /// 隐藏串 → 合法隐藏集合：未知项/重复剔除，**设置页一律剔除**（用户口径①）。
    /// 返回顺序即 allRaw 序（与渲染无关，只用于 UI 回显与相等判断）。
    static func sanitizedHidden(_ raw: String) -> [String] {
        let parsed = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for r in parsed where allRaw.contains(r) && canHide(raw: r) && !out.contains(r) { out.append(r) }
        return allRaw.filter { out.contains($0) }
    }

    /// 隐藏串的规范化写回形态（逗号串，按 allRaw 序；空集合 → 空串）
    static func encodeHidden(_ hidden: [String]) -> String {
        allRaw.filter { hidden.contains($0) }.joined(separator: ",")
    }

    /// 实际渲染的 dock = 顺序 − 隐藏，再兜一道「设置页必须在列」。
    /// `forcing` = 临时强制显示（深链 / 首页卡片点到被隐藏的页时把它插回来，见 DockTabView.forcedTabs）——
    /// 只在渲染期生效，不写回 UserDefaults（用户配置不被偷偷改掉）。
    static func visible(order: [String], hidden: [String], forcing: [String] = []) -> [String] {
        var out = order.filter { !hidden.contains($0) || forcing.contains($0) }
        if !out.contains(unHidableRaw) {
            // 坏数据兜底（sanitizedHidden 已拦一道，这里是渲染前的最后一道）：按原顺序插回设置页
            let idx = order.firstIndex(of: unHidableRaw) ?? out.count
            out.insert(unHidableRaw, at: min(idx, out.count))
        }
        return out.isEmpty ? [unHidableRaw] : out
    }

    /// 只读结论：给设置页/摘要用（顺序串 + 隐藏串 → 渲染档的 rawValue 列表）
    static func visibleRaw(orderRaw: String, hiddenRaw: String) -> [String] {
        visible(order: sanitizedOrder(orderRaw), hidden: sanitizedHidden(hiddenRaw))
    }

    /// 槽位序号（切页方向性微滑 / 浮层锚点几何按它算）。
    /// ⚠️ v4.0.82 起**不许**再写死 `slotIndex: 2` / `dockSlotCount: 4`：隐藏或换序后槽位数会变，
    ///    写死的几何会把浮层锚到别的槽上（v4.0.70 那版翻车的正是这类硬编码）。
    static func slotIndex(of raw: String, in visible: [String]) -> Int {
        visible.firstIndex(of: raw) ?? 0
    }
}
