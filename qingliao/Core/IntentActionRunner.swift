import Foundation
import SwiftUI
import UIKit

// MARK: - v3.9.71 意图动作执行器
//
// 动作条点了之后的一切副作用都在这里，**UI 不做判断也不直接写库**。
// 两条硬口径（沿用 v3.9.41 的教训）：
//   ① 不弹二次确认：写入类动作**点即写**，然后给 5 秒「撤销」（用户明确不喜欢整天审批）
//   ② 失败必须出声：返回 .failed，由动作条红字 + 震动（绝不静默失败——静默失败最伤信任）
//
// 撤销为什么会失效：QuickReminderStore/TodoStore 都是"写库即落本地 + 异步回写 NAS"，
// 撤销走的是**同一个 Store 的删除方法**，所以 NAS 那份也会被同步纠正，不会留下幽灵条目。

@MainActor
enum IntentActionRunner {

    enum Outcome {
        /// 成功。undo 非空时动作条给 5 秒撤销
        case done(message: String, undo: (() async -> Void)?)
        /// 外跳类（地图/拨号/邮件）：系统接管，不算失败也不需要提示
        case handedOff
        /// 转给聊天页发送（动作条自己发不了流）
        case askAI(String)
        case failed(String)
    }

    static func run(_ action: IntentAction, intent: RecognizedIntent, auth: AuthStore?) async -> Outcome {
        switch action {
        case .storeRecord:  return storeRecord(intent)
        case .addTodo:      return addTodo(intent)
        case .addReminder:  return await addReminder(intent)
        case .saveMemo:     return saveMemo(intent)
        case .saveToKB:     return await saveToKB(intent, auth: auth)
        case .openMap:      return openMap(intent)
        case .call:         return open("tel://\(digits(intent.fields["value"] ?? intent.raw))")
        case .mailto:       return open("mailto:\(intent.fields["value"] ?? intent.raw)")
        case .copy:         return copyRaw(intent)
        case .askAI:        return .askAI(intent.raw.isEmpty ? intent.title : intent.raw)
        }
    }

    // MARK: 写入类

    private static func storeRecord(_ intent: RecognizedIntent) -> Outcome {
        let amount = intent.fields["value"].flatMap { Double($0) }
        // 单位必须先归一再判 kind：端侧/云端给的是自由文本，"块钱""人民币"不归一就会被当读数，
        // 金额永远进不了本月合计（RecordKit.monthTotal 只算 unit == "元"）
        let unit = amount == nil ? "" : RecordKit.normalizeUnit(intent.fields["unit"] ?? "元")
        let kind = amount == nil ? "note" : (unit == "元" ? "amount" : "meter")
        // note 只留 200 字：记录与备忘/待办共用同一条 ≤3.5KB 的 relay 通道，
        // 整段原文会把 payload 顶爆（蜂窝下 relay 直接失败 = NAS 长期缺条）
        guard let added = RecordStore.shared.addDetailed(kind: kind, title: displayTitle(intent),
                                                        amount: amount, unit: unit,
                                                        note: String(intent.raw.prefix(200)),
                                                        source: "intent") else {
            return .failed("没记下来（内容为空）")
        }
        let item = added.item
        // 去重命中 = 没有新建条目 → 绝不能给撤销（一按就删掉先前那笔）
        guard added.inserted else {
            return .done(message: "刚记过同一笔，没重复记账", undo: nil)
        }
        return .done(message: amount == nil ? "已记一笔" : "已记录 \(item.amountText)",
                     undo: { RecordStore.shared.delete(item) })
    }

    private static func addTodo(_ intent: RecognizedIntent) -> Outcome {
        let text = displayTitle(intent, wide: true)
        guard TodoStore.shared.add(content: text, source: "intent") else {
            return .failed("没加进待办（内容为空）")
        }
        // TodoStore.add 只回 Bool → 用「内容 + 刚落库」认回那一条，撤销时删它
        let created = TodoStore.shared.todos.first {
            $0.content == text && Date().timeIntervalSince($0.createdAt) < 10
        }
        return .done(message: "已加进待办", undo: created.map { item in
            { TodoStore.shared.delete(item) }
        })
    }

    private static func addReminder(_ intent: RecognizedIntent) async -> Outcome {
        let source = intent.raw.isEmpty ? intent.title : intent.raw
        guard case .success(let parse) = QuickReminderParser.parseDetailed(source) else {
            return .failed("没认出提醒时间")
        }
        let store = QuickReminderStore.shared
        guard await store.add(text: source, parse: parse) else {
            return .failed(store.lastScheduleError ?? "没登记成功，检查通知权限")
        }
        let created = store.items.last
        return .done(message: "已建提醒 \(parse.summary)", undo: created.map { item in
            { await QuickReminderStore.shared.delete(item) }
        })
    }

    private static func saveMemo(_ intent: RecognizedIntent) -> Outcome {
        let text = intent.raw.isEmpty ? intent.title : intent.raw
        guard MemoStore.shared.add(content: text, source: "intent") else {
            return .failed("没存进备忘录（内容为空）")
        }
        let created = MemoStore.shared.memos.first {
            $0.content == text && Date().timeIntervalSince($0.createdAt) < 10
        }
        return .done(message: "已存备忘录", undo: created.map { item in
            { MemoStore.shared.delete(item) }
        })
    }

    private static func saveToKB(_ intent: RecognizedIntent, auth: AuthStore?) async -> Outcome {
        guard let auth else { return .failed("未登录，存不了知识库") }
        let text = intent.raw.isEmpty ? intent.title : intent.raw
        let name = intent.fields["host"] ?? displayTitle(intent)
        let body: [String: Any] = ["name": name, "content": text]
        guard let j = try? await auth.json("/api/kb/upload", method: "POST", body: body),
              (j["ok"] as? Bool) != false else {
            return .failed("知识库上传失败")
        }
        // 知识库没有单条删除接口 → 不给撤销（提示里说清楚存在哪）
        return .done(message: "已存进知识库", undo: nil)
    }

    // MARK: 外跳 / 复制 / 问 AI

    private static func openMap(_ intent: RecognizedIntent) -> Outcome {
        let q = intent.fields["text"] ?? intent.raw
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return .failed("这个地址打不开地图")
        }
        // 与聊天气泡同一套口径（v3.4.25 定的）：装了高德走高德（国内 POI 更准），否则退苹果地图。
        // 苹果地图用 **https**（原写法是 http，部分系统版本会拦；且 canOpenURL 对 http 不保证放行）。
        // 注：ChatMessageBubble.openInMaps 有一份等价实现，后续批次应抽成一个共享工具，本批不碰稳定路径。
        if let amap = URL(string: "iosamap://path?dname=\(encoded)&mode=route&src=qingliao"),
           UIApplication.shared.canOpenURL(amap) {
            UIApplication.shared.open(amap)
            return .handedOff
        }
        guard let url = URL(string: "https://maps.apple.com/?q=\(encoded)") else {
            return .failed("这个地址打不开地图")
        }
        UIApplication.shared.open(url)
        return .handedOff
    }

    private static func open(_ urlString: String) -> Outcome {
        guard let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) else {
            return .failed("没有能打开它的 App")
        }
        UIApplication.shared.open(url)
        return .handedOff
    }

    private static func copyRaw(_ intent: RecognizedIntent) -> Outcome {
        let text = intent.raw.isEmpty ? intent.title : intent.raw
        UIPasteboard.general.string = text
        return .done(message: "已复制", undo: nil)
    }

    // MARK: 工具

    /// 记录/待办标题：优先用用户原文（比"金额 128.50 元"更像人话）
    private static func displayTitle(_ intent: RecognizedIntent, wide: Bool = false) -> String {
        let raw = intent.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? intent.title : raw
        return String(base.prefix(wide ? 60 : 20))
    }

    private static func digits(_ s: String) -> String {
        s.filter { $0.isNumber || $0 == "+" }
    }
}
