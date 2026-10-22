// MARK: - v4.0.149 清单「滑掉」状态真值表（ProjectBatchDismissal）
//
// 背景：用户 2026-10-22「如果是已经完成的、已经滑掉的就不用显示了」→ 详情页左滑收起本批清单。
// 这类「本地持久状态」的坏法全是**编译不报、重启才现 / 隔几天才现**：
//   ① 用 String.hashValue 当指纹（每个进程随机加盐）→ 重启后收起状态时灵时不灵；
//   ② 存布尔而不是「本批指纹」→ 台账换了新批次，清单永远不回来（用户以为功能坏了）；
//   ③ 收起一个项目时把整串覆盖成只剩这一个 → 别的项目的收起状态被顺手清掉；
//   ④ 脏 AppStorage 数据（升级残留 / 手改）把整串读成空 → 全部收起状态一起消失。
// 本表钉这四类，用纯逻辑直接跑（不依赖 SwiftUI / iOS SDK）。

import Foundation

// Swift 6：顶层代码是 @MainActor，全局计数要从非隔离函数里改 → 显式 nonisolated(unsafe)（单线程测试）
nonisolated(unsafe) var passCount = 0
nonisolated(unsafe) var failCount = 0
func expect(_ name: String, _ ok: Bool) {
    if ok { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func entry(_ title: String, _ done: Bool) -> ProjectBatchDismissal.Entry {
    ProjectBatchDismissal.Entry(title: title, done: done)
}
let batchA = [entry("方案图定稿", true), entry("刷新改回全站胶囊口径", true)]
let batchAOther = [entry("方案图定稿", false), entry("刷新改回全站胶囊口径", true)]   // 勾选变了
let batchB = [entry("新一批：暗色模式", false)]                                       // 换批次

// ── 1. 指纹：稳定 + 内容敏感 + 顺序敏感 ──────────────────────
let fpA = ProjectBatchDismissal.fingerprint(batchA)
expect("同一批 → 指纹稳定（两次算一样）", fpA == ProjectBatchDismissal.fingerprint(batchA))
expect("指纹非空且是十六进制（AppStorage 里好存好比）",
      !fpA.isEmpty && fpA.allSatisfy { $0.isHexDigit })
expect("勾选变化 → 指纹不同（勾完最后一条算新的一批）",
      fpA != ProjectBatchDismissal.fingerprint(batchAOther))
expect("条目变化 → 指纹不同（换批次要能自动重新显示）",
      fpA != ProjectBatchDismissal.fingerprint(batchB))
expect("顺序变化 → 指纹不同（两条互不冒充）",
      fpA != ProjectBatchDismissal.fingerprint(Array(batchA.reversed())))
expect("空清单 → 也有确定指纹（不崩）",
      !ProjectBatchDismissal.fingerprint([]).isEmpty)

// ── 2. 收起 / 撤销 的基本语义 ────────────────────────────────
let afterHide = ProjectBatchDismissal.hiding("", slug: "qingliao-ios", fingerprint: fpA)
expect("收起后：同批命中", ProjectBatchDismissal.isHidden(afterHide, slug: "qingliao-ios", fingerprint: fpA))
expect("收起后：换批次不命中（新批次要显示出来）",
      !ProjectBatchDismissal.isHidden(afterHide, slug: "qingliao-ios", fingerprint: ProjectBatchDismissal.fingerprint(batchB)))
expect("收起后：别的项目不受影响",
      !ProjectBatchDismissal.isHidden(afterHide, slug: "qingliao-backend", fingerprint: fpA))
let afterUndo = ProjectBatchDismissal.showing(afterHide, slug: "qingliao-ios")
expect("撤销后：同批不再命中（清单回来）",
      !ProjectBatchDismissal.isHidden(afterUndo, slug: "qingliao-ios", fingerprint: fpA))

// ── 3. 多项目隔离：收起一个不许顺手清掉别的 ──────────────────
let fpBackend = ProjectBatchDismissal.fingerprint([entry("EROFS 删除失败可读", true)])
var multi = ProjectBatchDismissal.hiding("", slug: "qingliao-ios", fingerprint: fpA)
multi = ProjectBatchDismissal.hiding(multi, slug: "qingliao-backend", fingerprint: fpBackend)
expect("两个项目都记下",
      ProjectBatchDismissal.isHidden(multi, slug: "qingliao-ios", fingerprint: fpA)
      && ProjectBatchDismissal.isHidden(multi, slug: "qingliao-backend", fingerprint: fpBackend))
let onlyBackend = ProjectBatchDismissal.showing(multi, slug: "qingliao-ios")
expect("撤销 A：A 回来、B 仍收起",
      !ProjectBatchDismissal.isHidden(onlyBackend, slug: "qingliao-ios", fingerprint: fpA)
      && ProjectBatchDismissal.isHidden(onlyBackend, slug: "qingliao-backend", fingerprint: fpBackend))

// ── 4. 串行化：顺序无关、脏数据不炸、空 slug 不落盘 ──────────
let ab = ProjectBatchDismissal.hiding(ProjectBatchDismissal.hiding("", slug: "a", fingerprint: "11"), slug: "b", fingerprint: "22")
let ba = ProjectBatchDismissal.hiding(ProjectBatchDismissal.hiding("", slug: "b", fingerprint: "22"), slug: "a", fingerprint: "11")
expect("写入顺序不同 → 串一致（不会反复改写 AppStorage）", ab == ba)
expect("串里两条都在", ProjectBatchDismissal.map(ab).count == 2)
for dirty in ["garbage", "a:", ":11", ",,,", ":::"] {
    expect("脏数据「\(dirty)」不崩且不会假装命中",
          !ProjectBatchDismissal.isHidden(dirty, slug: "a", fingerprint: "11"))
}
expect("脏数据里可用的那截仍生效（a:11,,b 里 a 仍命中）",
      ProjectBatchDismissal.isHidden("a:11,,b", slug: "a", fingerprint: "11"))
expect("空 slug 不落盘（返回原串）",
      ProjectBatchDismissal.hiding(ab, slug: "", fingerprint: fpA) == ab)
expect("空指纹不落盘（返回原串）",
      ProjectBatchDismissal.hiding(ab, slug: "x", fingerprint: "") == ab)
expect("空 slug / 空指纹查不到命中",
      !ProjectBatchDismissal.isHidden(ab, slug: "", fingerprint: "11")
      && !ProjectBatchDismissal.isHidden(ab, slug: "a", fingerprint: ""))

print("清单「滑掉」状态真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
