// v4.0.104 待做池⑫ 专注计时真值表用的**最小键替身** —— 只为了让 FocusTimerStore 能单独编译。
//
// ⚠️ 这里只放一个常量、且必须与 qingliao/Core/Models.swift 里的 UserDefaultsKey.focusSession
//    逐字相同（真值表 C 段会拿 Models.swift 的字面量来比对，防止替身与真源漂移）。
enum UserDefaultsKey {
    static let focusSession = "qingliao_focus_session"
}
