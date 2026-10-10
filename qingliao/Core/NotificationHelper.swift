import Foundation
import UserNotifications

// MARK: - v2.0.36 本地通知（AI 回复完成提醒等）

enum NotificationHelper {
    /// v3.4.23：App 图标角标——跟随任务中心未读数（收到任务/推送时 +1，进任务中心查看清零）
    static func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, min(count, 99)))
    }

    /// App 启动时请求通知权限（记录结果，便于排查通知不弹的问题）
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("[NOTIFY] auth error: \(error)") }
            if !granted { NSLog("[NOTIFY] ⚠️ 通知权限被拒绝，AI 回复完成提醒将不可用") }
        }
        // v3.9.32：启动顺带对账一次「一句话定时提醒」（幂等）——过期的一次性提醒标 fired、
        // 未过期的按稳定 identifier 重注册、系统里的孤儿请求清掉。挂在这里而不是 QingliaoApp.swift：
        // 本方法就是 App 启动的唯一通知子系统入口（全仓仅 QingliaoApp.swift:34 调用）。
        // 若后续想在 QingliaoApp 里显式写这一行，把下面这行挪过去即可——两处都调也安全（reconcile 幂等）。
        Task { @MainActor in await QuickReminderStore.shared.reconcile() }
    }

    /// 发送一条本地通知（App 退后台时用）；v2.0.60 支持携带会话 id（点击直达）
    /// v3.0.x fix：使用语义化 identifier 支持同内容通知替换（防快速连续推送堆叠多条）
    /// v3.4.x code review fix（中）：改用稳定 djb2 哈希替代 String.hashValue——hashValue 带进程随机
    /// 种子，跨启动相同 body 生成不同 identifier（同内容替换只在同进程内成立，重启后推送仍堆叠）；
    /// 并去掉 abs()（hash == Int.min 时 abs 溢出崩溃）。负值用 UInt64 位模式自然消除。
    ///
    /// v4.0.91（配合 iOS 27 快捷指令）：标题不再各处自定义，统一由 `kind` 决定前缀
    /// （【轻聊·提醒】/【轻聊·回复】/【轻聊·主动】/【轻聊·待确认】/【轻聊·投递】/【轻聊·告警】），
    /// 于是系统「收到通知」触发器可以按**标题前缀**判类别；`detail` 进副标题（关键值，如提醒时间），
    /// 正文只放内容。组装规则全在 QingliaoNotifyCopy（纯 Foundation，本机真值表可验）。
    static func notify(kind: QingliaoNotifyKind, body: String, detail: String? = nil,
                       sessionId: String? = nil, sound: Bool = true) {
        let copy = QingliaoNotifyCopy.compose(kind, detail: detail, body: body)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        // 副标题：nil 时**不设**（设空串会让通知里多出一行空白）
        if let sub = copy.subtitle { content.subtitle = sub }
        content.body = copy.body
        // v4.0.20：#10 通知分层——后台推进（cron/system）走静默，不抢前台对话的铃声。
        //（前端对话完成 / AI 主动开口 / 追问仍响：那三类需要用户当场处理）
        if sound { content.sound = .default }
        if let sid = sessionId {
            content.userInfo = ["qingliao_session": sid]
        }
        // 固定前缀 + 稳定内容哈希做 identifier，相同内容跨启动也替换旧通知（不堆叠）
        let identifier = "qingliao_push_" + String(stableHash(copy.body), radix: 16)
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// v3.4.26：AI 回复完成通知——正文取回复首句（不点亮屏幕也能瞥见答了什么）
    /// v4.0.91：首句提取搬到 QingliaoNotifyCopy.replyPreview（纯函数，本机真值表钉着），
    /// 标题走 .reply 前缀（【轻聊·回复】）——自动化的「AI 回复来了」条件就靠它。
    static func notifyReply(_ reply: String, sessionId: String?) {
        let preview = QingliaoNotifyCopy.replyPreview(reply)
        notify(kind: .reply,
               body: preview.isEmpty ? "AI 回复完成，点击查看" : "💬 " + preview,
               detail: "AI 回复完成",
               sessionId: sessionId)
    }

    /// djb2 稳定哈希（与 ChatStore.stableHash 同款；UInt64 无符号 → 天然无 abs 溢出问题）
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return h
    }
}
