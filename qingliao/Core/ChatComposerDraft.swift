import Foundation
import Observation

/// v4.0.151：聊天输入框正文的**状态载体**（唯一实例由 `ChatView` 的 `@State` 持有）。
///
/// 为什么不是一个普通的 `@State var inputText: String`（v4.0.150 及以前就是）：
/// 输入框正文是「每敲一个键都变」的高频状态，它原先住在 ChatView 上 →
/// 每敲一键 SwiftUI 都会把**整个聊天页**重建一遍（消息列表 + 全部浮层 + 二十多条
/// onChange/sheet 修饰器）。会话越长、屏上长气泡越多，这一遍越贵 ——
/// 真机表现就是用户报的「聊得越久，打字越卡、键盘按半天不出字」。
///
/// 换成 `@Observable` 引用类型之后，观察粒度收窄到**真正读了 `text` 的视图**
/// （只有 `ChatInputBar`），打字不再连坐消息列表与整页 chrome。
///
/// 🚨 三条红线（改这个文件之前先看）：
///   ① **别改回 `@State String`**：ql_draft 真值表钉着「正文不是 @State 字符串」。
///   ② **`ChatView.body` 里不许读 `text`**：读了 = 整页又跟着每次按键失效，本类白搭。
///      所有要由正文派生的展示值（如斜杠命令面板的前缀）一律下放到 `ChatInputBar`
///      自己从 `text` binding 派生（它读 = 它自己重绘，页级视图不动）。
///   ③ **别加 `@MainActor`**：ChatView 上的非隔离计算属性 / Binding 闭包要读写 `text`，
///      加了就是 CI Archive 的 `main actor-isolated property can not be referenced
///      from a nonisolated context`（本仓 StreamClient / AuthStore 同样是不带 @MainActor 的
///      @Observable，照它们写）。写入口本来就全在 MainActor 路径上，不需要这层注解。
@Observable
final class ChatComposerDraft {
    var text: String = ""
}
