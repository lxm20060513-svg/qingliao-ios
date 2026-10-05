import SwiftUI
import UIKit   // v4.0.61：正文接入 Dynamic Type 用 UIFontMetrics（SwiftUI 不转发 UIKit 符号）

// MARK: - v3.9.0 全站字号令牌（Typography）
//
// 背景：改造前 `.font(.system(size: …))` 散落 **22 个不同数值**（7.5 / 8.5 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 /
// 12 / 12.5 / 13 / 13.5 / 14 / 15 / 16 / 17 / 18 / 19 / 20 / 22 / 24 / 26 / 28 / 30 / 32 / 34 / 40 / 44 / 52 / 76），
// 其中 11 / 12 / 13 三档共 424 处、彼此只差 1pt —— 视觉层级糊，是"不够精致"的主因。
//
// 目标：**文字字号收敛为 8 档语义层级**（每处移动幅度刻意控制在 ≤2pt；本机无 SDK 无法目视验证，
// 大步长重排风险远大于收益，需要大改时应在真机逐屏确认后单独进行）。
//
// 语义分层（越往下越大，不要跨层乱用）：
//   tiny      角标 / 极小注释（原 7.5–10.5）
//   caption   次要说明文字（原 11–11.5）
//   subhead   列表次要文字 / 标签（原 12–13.5）
//   body      正文（原 14–15）
//   title     小标题 / 卡片数值（原 16–17）
//   headline  卡片 / 弹窗标题（原 18–20）
//   titleXL   大数字 / 突出标题（原 22–24）
//   display   空态插画 / 大标题（原 26–30）
//
// ⚠️ **装饰字号不在此体系内**：≥32 的（32 / 34 / 40 / 44 / 52 / 76）是启动页、登录页大图标、空态插画、
// 任务中心标题等一次性装饰尺寸，**保持原值不动**（SplashView 等属已定稿美术方向）。
//
// 用 static let（CGFloat 是值类型，Swift 6 严格并发无全局状态告警问题；Animation 才需要计算属性）。

enum Typography {
    /// 角标 / 极小注释
    static let tiny: CGFloat = 10
    /// 次要说明文字
    static let caption: CGFloat = 11
    /// 列表次要文字 / 标签
    static let subhead: CGFloat = 13
    /// 正文
    ///
    /// v4.0.61（用户 2026-10-05 拍板「借鉴 iOS 原生风格」第①条）：**正文字号跟随系统「文字大小」**
    /// （Dynamic Type）。做法是 UIFontMetrics 按 `.body` 档缩放同一个数值 —— 字重/字距/层级全不变，
    /// 只让大小跟系统走；系统没调过时返回值恰好是 15，观感零变化（所以这不是"重排"，是"接管"）。
    ///
    /// ⚠️ **只放正文一类跟随**：胶囊（`PillSize` 走 subhead/tiny）、栏目标题、卡片数值都**保持固定** ——
    ///    胶囊宽度、列表行高都按固定字号量过，跟随缩放会截字/撑高。
    /// ⚠️ 上限 = `title`(17)，不再用 +40%（v4.0.61 审查意见 5）：
    ///    21 会反超卡片数值(17) 与弹窗标题(20)，层级反转；且本仓大量卡片高度写死，撑爆风险高。
    /// ⚠️ 未做缓存（审查意见 4b）：加缓存需读全局 trait（`UIApplication.shared…`/@MainActor），
    ///    在 nonisolated static 里会引入并发隔离问题；而 UIFontMetrics 构造本身轻量，实测可忽略。
    static var body: CGFloat {
        min(UIFontMetrics(forTextStyle: .body).scaledValue(for: 15), 17)
    }
    /// 小标题 / 卡片数值
    static let title: CGFloat = 17
    /// 卡片 / 弹窗标题
    static let headline: CGFloat = 20
    /// 大数字 / 突出标题
    static let titleXL: CGFloat = 24
    /// 空态插画 / 大标题
    static let display: CGFloat = 28
}

// MARK: - v3.9.19 全站行距令牌（LineSpacing）
//
// 背景：改造前 `.lineSpacing(…)` 的静态值散落 2 / 3 / 4 / 6 四种，同为「AI 生成长正文」却有三种手感
// （资讯正文 4、备忘录详情 6、会话导出 6）——同类文本不一致，长文阅读的松紧随场景漂移。
//
// ⚠️ **聊天会话的 AI 消息不在此体系内**：那里的行距是用户设置项 `qingliao_ai_line_spacing`
//（设置 →「AI 输出行高」滑块，紧凑↔宽松 0…6、step 0.5、默认 1.0；原 CloudSettingsView 已随云端模式移除）。
// **用户设置优先，不要换成令牌**；令牌只服务「没有设置项兜底」的静态文本。
enum LineSpacing {
    /// 长文正文（≥15pt 的连续阅读文本：资讯 AI 正文、备忘录详情 / 编辑、会话导出）
    static let long: CGFloat = 6
    /// 紧凑说明（卡片副文本、会话列表行、用户消息默认、pin 预览）
    static let compact: CGFloat = 3
}
