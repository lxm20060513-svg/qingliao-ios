import SwiftUI

// MARK: - 生活页小胶囊按钮（v3.9.71：抽成共享，别再各文件抄一份）
//
// 为什么要有这个文件（真实事故，不是洁癖）：
//   这个组件原来在 MemoSection.swift 与 TodoSection.swift 里各有一份 `private struct`。
//   文件级 private = 跨文件不可见，所以第三个使用者 RecordSection 直接写 `MiniCapsule(...)` 时
//   编译报 `cannot find 'MiniCapsule' in scope`——而本机预检（check_swift.sh 第 1 步）只跑
//   `swiftc -parse`，**纯语法解析、不做名字解析**，当场全绿，只有 CI Archive 才炸。
//   规则：跨文件复用的组件必须是**非 private 的单一来源**；同类先例是 MemoCardMetrics（当年把
//   private 去掉给 TodoSection 复用），MiniCapsule 当时没去 private 才留下这个雷。
//
// 口径：`.pill(.topBar, tone:)` + `PressStyle()`（v3.9.19 起不再用实色底 accent 分支）。

struct MiniCapsule: View {
    let title: String
    var accent: Bool = false
    /// v4.0.47（用户 2026-10-04）：档位可调，默认 `.topBar`（13pt，全站顶栏/工具条口径）。
    /// 传 `.page` = 与生活页栏目头「添加」同档的小胶囊（10pt + h10/v4）——长期目标的状态胶囊
    /// 降档后，紧挨它的「现在开始推进」必须同档，否则并排两枚胶囊不一样高。
    /// ⚠️ 声明位置在 `action` **之前**：调用方多用尾随闭包写 action，参数只能按声明序传。
    var size: PillSize = .topBar
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // v3.9.19：走 .pill(.topBar) 口径；原 accent 分支是实色底，改为口径内的淡底（与全站一致）
            // v3.9.22：.topBar 档字号 tiny(10) → subhead(13)，用户反馈这些小胶囊文字偏小
            Text(title)
                .pill(size, tone: accent ? .accent : .neutral)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}
