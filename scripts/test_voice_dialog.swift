import Foundation

// MARK: - v3.9.76 语音对话轮次真值表（纯逻辑，本机可跑）
//
// 覆盖用户拍板的三条口径 + 四条「真机上偶发、复现极难」的坑：
//   ① 用户口径：停顿 2 秒自动发；**点一下发送也要能发**（两种都要，不限模式）
//   ② 用户口径：AI 回复**全念** → 念的时候必须停麦（半双工），否则录到自己的声音自问自答
//   ③ 坑 A：等待/朗读期间麦克风漏进来的字**绝不能**进草稿（会带着 AI 的半句话发出去）
//   ④ 坑 B：同一段文本重复回调若不判重，判停时间被无限刷新 → **永远发不出去**
//   ⑤ 坑 C：等回复/等朗读没有兜底超时 → 永久停在等待态，麦克风锁死（"说第二句没反应"）
//   ⑥ 坑 D：聊天页手动点气泡朗读不该推进语音对话轮次（只有「等待回复」中出现才算）
//   ⑦ 坑 E：空草稿到点自动发 = 把空气发出去

var pass = 0
var fail = 0
func check(_ name: String, _ ok: Bool) {
    if ok { pass += 1; print("✅ " + name) }
    else { fail += 1; print("❌ " + name) }
}

let t0 = Date()
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

// ── ① 启动与麦克风 ─────────────────────────────────────────
var e = VoiceDialogEngine()
check("start → 收音中并要求开麦", e.handle(.start, now: t0) == .openMic && e.phase == .listening)
check("重复 start 不重复开麦（防叠一次收音）",
      e.handle(.start, now: t0) == .none && e.phase == .listening)

// ── ② 听到内容只累积 ───────────────────────────────────────
check("听到内容只累积草稿、不立刻发",
      e.handle(.heard("帮我看看工业富联今天的收盘价"), now: t0) == .none
      && e.draft == "帮我看看工业富联今天的收盘价")

// ── ③ 判停窗口（2.0 秒，用户拍板）────────────────────────────
check("停顿 1.9 秒不发（1 秒切半句、太短）",
      e.handle(.tick(at(1.9)), now: at(1.9)) == .none && e.phase == .listening)
check("停顿满 2.0 秒自动发送",
      e.handle(.tick(at(2.0)), now: at(2.0)) == .sendNow("帮我看看工业富联今天的收盘价"))
check("自动发送后进入等待态", e.phase == .sending)
// ⚠️ 这里原来写「（此时不开麦）」但**没有断言那件事**（当时源码也确实没停麦）= 名不副实的护栏，
//    会把真缺口盖成绿。现在停麦由 `Action.sendNow` 的语义 + VoiceDialogView.perform 一起保证
//    （源护栏在 ql_orbmenu 表），引擎侧能钉的是这个标记：本轮「已发出、还没念过」。
check("发送后 awaitingSpeech = true（这一轮还没念过）", e.awaitingSpeech)

// ── ④ 坑 A：等待态漏进来的字必须丢弃 ─────────────────────────
check("等待态听到内容被丢弃（不污染下一轮）",
      e.handle(.heard("工业富联今天收"), now: at(3.0)) == .none && e.draft.isEmpty)

// ── ⑤ 半双工：朗读停麦 / 念完开麦 ───────────────────────────
check("开始朗读 → 朗读态并要求关麦",
      e.handle(.speechStarted, now: at(3.2)) == .closeMic && e.phase == .speaking)
check("朗读态听到内容被丢弃（不能录到自己念的）",
      e.handle(.heard("六十八块"), now: at(3.5)) == .none && e.draft.isEmpty)
check("念完 → 回到收音并要求开麦",
      e.handle(.speechEnded, now: at(9.0)) == .openMic && e.phase == .listening)
check("念完轮次 +1", e.rounds == 1)
check("念完草稿清空（下一轮从零开始）", e.draft.isEmpty)

// ── ⑥ 坑 E：空草稿到点也不发 ───────────────────────────────
check("空草稿停顿到点不发（别把空气发出去）",
      e.handle(.tick(at(12.0)), now: at(12.0)) == .none && e.phase == .listening)

// ── ⑦ 用户口径：自动模式下也能手动提前发（「两个都要」）────────
check("自动模式下手动点发送也发",
      e.handle(.heard("第二句"), now: at(13.0)) == .none
      && e.handle(.send, now: at(13.5)) == .sendNow("第二句"))
_ = e.handle(.speechStarted, now: at(14.0))
_ = e.handle(.speechEnded, now: at(20.0))
check("第二轮计数正确（连续多轮不串）", e.rounds == 2 && e.phase == .listening)

// ── ⑧ 手动模式：静音到点不发，必须点发送 ────────────────────
var m = VoiceDialogEngine()
m.mode = .manual
_ = m.handle(.start, now: t0)
_ = m.handle(.heard("手动模式这句话"), now: t0)
check("手动模式下停顿到点不发",
      m.handle(.tick(at(9.0)), now: at(9.0)) == .none && m.phase == .listening)
check("手动模式下点发送才发",
      m.handle(.send, now: at(9.5)) == .sendNow("手动模式这句话"))

// ── ⑨ 坑 B：重复回调不刷新判停 ─────────────────────────────
var d = VoiceDialogEngine()
_ = d.handle(.start, now: t0)
_ = d.handle(.heard("重复回调"), now: t0)
_ = d.handle(.heard("重复回调"), now: at(1.9))       // 同内容：不算新内容
check("同内容重复回调不刷新判停（到点照样发）",
      d.handle(.tick(at(2.0)), now: at(2.0)) == .sendNow("重复回调"))

// ── ⑩ 坑 C：等回复兜底超时 ─────────────────────────────────
var w = VoiceDialogEngine()
_ = w.handle(.start, now: t0)
_ = w.handle(.heard("喂"), now: t0)
_ = w.handle(.tick(at(2.0)), now: at(2.0))            // waitingSince = 2.0
check("等待 18 秒不回收音（模型慢是正常的）",
      w.handle(.tick(at(20.0)), now: at(20.0)) == .none && w.phase == .sending)
check("等待 24.9 秒仍未回收（贴边界不误杀）",
      w.handle(.tick(at(26.9)), now: at(26.9)) == .none && w.phase == .sending)
check("等待满 25 秒 → 回收音（麦克风绝不锁死）",
      w.handle(.tick(at(27.1)), now: at(27.1)) == .openMic && w.phase == .listening)
// ⑩′ 兜底回收音**之后** AI 才开始念：迟到的 speechStarted 必须仍然有效并停麦 ——
//     否则麦克风与扬声器同开，录到自己的朗读 → 停顿 2 秒把 AI 的话发出去（自问自答）。
check("超时回收音后，迟到的 speechStarted 仍能停麦",
      w.handle(.speechStarted, now: at(28.0)) == .closeMic && w.phase == .speaking)
check("念完 → 回到收音且轮次 +1", w.handle(.speechEnded, now: at(33.0)) == .openMic && w.rounds == 1)

// ── ⑪ 坑 D：气泡朗读不推进轮次 ─────────────────────────────
var b = VoiceDialogEngine()
_ = b.handle(.start, now: t0)
check("收音态收到朗读开始不推进（手动点气泡朗读不该算一轮）",
      b.handle(.speechStarted, now: t0) == .none && b.phase == .listening)

// ── ⑫ 退出与重开 ───────────────────────────────────────────
check("stop → 结束并要求关麦", b.handle(.stop, now: t0) == .closeMic && b.phase == .ended)
check("结束后 start 可重开", b.handle(.start, now: t0) == .openMic && b.phase == .listening)
// ⑫′ 退出的两个真实场景：原来只测了 listening 态退出，而「退出后还在响 / 还在收音」
//     恰恰出在这两态（AI 正在念时退出、等回复时退出）。
var sp = VoiceDialogEngine()
_ = sp.handle(.start, now: t0)
_ = sp.handle(.heard("念到一半退出"), now: t0)
_ = sp.handle(.tick(at(2.0)), now: at(2.0))          // → sending
_ = sp.handle(.speechStarted, now: at(3.0))          // → speaking
check("朗读中退出 → 关麦 + ended",
      sp.handle(.stop, now: at(4.0)) == .closeMic && sp.phase == .ended)
var sd = VoiceDialogEngine()
_ = sd.handle(.start, now: t0)
_ = sd.handle(.heard("等回复时退出"), now: t0)
_ = sd.handle(.tick(at(2.0)), now: at(2.0))          // → sending
check("等回复时退出 → 关麦 + ended",
      sd.handle(.stop, now: at(3.0)) == .closeMic && sd.phase == .ended)

// ── ⑬ 全双工：朗读期间插话（v4.1.x 打电话）─────────────────────
var fd = VoiceDialogEngine()
fd.fullDuplex = true
_ = fd.handle(.start, now: t0)
_ = fd.handle(.heard("帮我查一下"), now: t0)
_ = fd.handle(.tick(at(2.0)), now: at(2.0))          // → sending
check("全双工：开始朗读时重开麦清缓冲（不是只 openMic）",
      fd.handle(.speechStarted, now: at(3.0)) == .restartMic && fd.phase == .speaking)
check("全双工：AI 自己的话被回声闸门丢弃",
      fd.handle(.heardDuringSpeech("今天收盘六十八块", spoken: "今天收盘六十八块四"),
                now: at(3.4)) == .none
      && fd.draft.isEmpty && fd.phase == .speaking)
check("全双工：用户插话 → 停朗读并进入收音",
      fd.handle(.heardDuringSpeech("等等先别说了", spoken: "今天收盘六十八块四"),
                now: at(4.0)) == .interruptAndListen
      && fd.phase == .listening && fd.draft == "等等先别说了")
check("全双工：插话后继续说话仍剥掉 AI 前缀",
      fd.handle(.heard("今天收盘六十八块四等等先别说了再说一句"),
                now: at(4.4)) == .none
      && fd.draft == "等等先别说了再说一句")
check("全双工：带当前已念全文时能剥掉残余朗读",
      fd.handle(.heardWithSpoken("今天收盘六十八块四毛二等等先别说了",
                                spoken: "今天收盘六十八块四毛二"),
                now: at(4.5)) == .none
      && fd.draft == "等等先别说了")
check("全双工：插话 1.9 秒还不发",
      fd.handle(.tick(at(5.9)), now: at(5.9)) == .none)
check("全双工：插话满 2 秒自动发",
      fd.handle(.tick(at(6.5)), now: at(6.5)) == .sendNow("等等先别说了"))
check("全双工：下一轮朗读仍重开麦、念完再重开麦清缓冲",
      fd.handle(.speechStarted, now: at(7.0)) == .restartMic
      && fd.handle(.speechEnded, now: at(9.0)) == .restartMic
      && fd.rounds == 1)
check("全双工：迟到的下一段起播仍能接管（不丢段、不裸麦）",
      fd.handle(.speechSegmentStarted, now: at(10.0)) == .restartMic
      && fd.phase == .speaking)

// 收音态普通 speechStarted（手动朗读/推送朗读）不能推进阶段；只有续段事件才行
var fs = VoiceDialogEngine()
fs.fullDuplex = true
_ = fs.handle(.start, now: t0)
check("全双工：收音态普通 speechStarted 不推进（防手动/推送朗读误判）",
      fs.handle(.speechStarted, now: at(1.0)) == .none && fs.phase == .listening)
check("全双工：只有 speechSegmentStarted 才接管续段",
      fs.handle(.speechSegmentStarted, now: at(1.1)) == .restartMic
      && fs.phase == .speaking)

// 全双工防误触：起播噪声 / 少字语气词都不能打断正常回答
var fn = VoiceDialogEngine()
fn.fullDuplex = true
_ = fn.handle(.start, now: t0)
_ = fn.handle(.heard("你好"), now: t0)
_ = fn.handle(.tick(at(2.0)), now: at(2.0))
_ = fn.handle(.speechStarted, now: at(3.0))
check("全双工：TTS 还没念出字时，噪声不算插话",
      fn.handle(.heardDuringSpeech("嗯", spoken: ""), now: at(3.2)) == .none
      && fn.phase == .speaking)
check("全双工：1~2 个字的语气词不打断",
      fn.handle(.heardDuringSpeech("停", spoken: "今天收盘六十八块四"),
                now: at(3.3)) == .none
      && fn.phase == .speaking)
check("全双工：3 个字以上才允许插话",
      fn.handle(.heardDuringSpeech("停一下", spoken: "今天收盘六十八块四"),
                now: at(3.4)) == .interruptAndListen
      && fn.phase == .listening)
check("结束幂等：第二次 stop 不再重复关麦",
      fn.handle(.stop, now: at(4.0)) == .closeMic
      && fn.handle(.stop, now: at(4.1)) == .none)

// 半双工必须保持原口径：朗读期间听到的内容一律丢弃
var hd = VoiceDialogEngine()
_ = hd.handle(.start, now: t0)
_ = hd.handle(.heard("半双工这句"), now: t0)
_ = hd.handle(.tick(at(2.0)), now: at(2.0))
_ = hd.handle(.speechStarted, now: at(3.0))
check("半双工：朗读期间听到内容仍被丢弃（不能改成插话）",
      hd.handle(.heardDuringSpeech("插话", spoken: "")) == .none
      && hd.draft.isEmpty && hd.phase == .speaking)
check("半双工：念完仍然只开麦（不重开清缓冲）",
      hd.handle(.speechEnded, now: at(5.0)) == .openMic)

// 回声闸门（纯函数）
check("回声闸门：已念文本的开头 → 回声",
      CallEchoGate.isEcho("今天收盘六十八块", spoken: "今天收盘六十八块四毛二"))
check("回声闸门：只听到已念文本的尾巴也算回声（麦开晚了 / 数字被改写）",
      CallEchoGate.isEcho("八块四", spoken: "今天收盘六十八块四毛二"))
check("回声闸门：中间词重合不算回声（真实插话：别订机票）",
      !CallEchoGate.isEcho("别订机票", spoken: "我现在帮你订机票"))
check("回声闸门：标点空格不影响判定",
      CallEchoGate.isEcho("今天收盘 六十八块四！", spoken: "今天收盘六十八块四毛二"))
check("回声闸门：真插话不判回声",
      !CallEchoGate.isEcho("等等先别说了", spoken: "今天收盘六十八块四毛二"))
check("回声闸门：已念文本还是空时不拦（还没开口就插话）",
      !CallEchoGate.isEcho("等一下", spoken: ""))
check("回声剥离：AI 前缀 + 用户插话 → 只留用户那截",
      CallEchoGate.userPart("今天收盘六十八块四等等先别说了",
                            spoken: "今天收盘六十八块四毛二") == "等等先别说了")
check("回声剥离：纯用户话原样保留",
      CallEchoGate.userPart("等等先别说了", spoken: "今天收盘六十八块四毛二") == "等等先别说了")
check("回声剥离：整段回声 → 空串",
      CallEchoGate.userPart("今天收盘六十八块四毛二",
                            spoken: "今天收盘六十八块四毛二").isEmpty)

if fail == 0 {
    print("🎉 语音对话轮次真值表全部通过（\(pass) 条）")
} else {
    print("💥 语音对话轮次真值表：\(pass) 通过 / \(fail) 失败")
}
exit(fail == 0 ? 0 : 1)
