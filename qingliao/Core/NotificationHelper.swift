import Foundation
import UserNotifications

// MARK: - v2.0.36 本地通知（AI 回复完成提醒等）

enum NotificationHelper {
    /// App 启动时请求通知权限（记录结果，便于排查通知不弹的问题）
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("[NOTIFY] auth error: \(error)") }
            if !granted { NSLog("[NOTIFY] ⚠️ 通知权限被拒绝，AI 回复完成提醒将不可用") }
        }
    }

    /// 发送一条本地通知（App 退后台时用）；v2.0.60 支持携带会话 id（点击直达）
    /// v3.0.x fix：使用语义化 identifier 支持同内容通知替换（防快速连续推送堆叠多条）
    /// v3.4.x code review fix（中）：改用稳定 djb2 哈希替代 String.hashValue——hashValue 带进程随机
    /// 种子，跨启动相同 body 生成不同 identifier（同内容替换只在同进程内成立，重启后推送仍堆叠）；
    /// 并去掉 abs()（hash == Int.min 时 abs 溢出崩溃）。负值用 UInt64 位模式自然消除。
    static func notify(title: String, body: String, sessionId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sid = sessionId {
            content.userInfo = ["qingliao_session": sid]
        }
        // 固定前缀 + 稳定内容哈希做 identifier，相同内容跨启动也替换旧通知（不堆叠）
        let identifier = "qingliao_push_" + String(stableHash(body), radix: 16)
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// djb2 稳定哈希（与 ChatStore.stableHash 同款；UInt64 无符号 → 天然无 abs 溢出问题）
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 5381
        for b in s.utf8 { h = h &* 33 &+ UInt64(b) }
        return h
    }
}
