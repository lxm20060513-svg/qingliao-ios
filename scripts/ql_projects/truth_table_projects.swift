// MARK: - v4.0.143 工作台「进行项目」真值表
//
// 背景：用户 2026-10-21「工作台新增进行项目栏位，显示 Hermes 在做的各个项目的状态 /
// 进度 / 当前版本 / 最近更新」。这类「数据聚合卡」的坏法全是**编译不报、真机才现**：
//   ① 数据源写错前缀（/api/projects 而不是 /api/agent/projects）→ lucky(16666) 404，
//      App 里那块永远空着，看起来像「没有项目」而不是「接口挂了」；
//   ② 没清单也画进度条 → 永远 0% 或 100%，比不画更误导（方案图第 5 条口径）；
//   ③ 每次拉取失败就清空列表 → 网络抖一下，卡就消失；
//   ④ 详情页「完成」放到右侧 → 违反全站弹窗口径（设置页间距真值表会红）；
//   ⑤ 淡底色写字面量 0.14/0.15 → 色彩令牌表会红（同屏两种写法，下一轮 grep 只找得到一半）。
// 本表盯这几类，并把「挂点唯一 + 顺序」钉死。

import Foundation

var passCount = 0
var failCount = 0
func check(_ name: String, _ cond: Bool) {
    if cond { passCount += 1 } else { failCount += 1; print("❌ \(name)") }
}

func src(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

func occurrences(_ s: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var n = 0, idx = s.startIndex
    while let r = s.range(of: needle, range: idx..<s.endIndex) {
        n += 1
        idx = r.upperBound
        if idx >= s.endIndex { break }
    }
    return n
}

let ws = src("qingliao/Features/Workspace/WorkspaceView.swift")
let sec = src("qingliao/Features/Workspace/WorkspaceProjectsSection.swift")
let kit = src("qingliao/Core/ProjectsKit.swift")

// ── 0. 文件都在（读不到 = 下面全是空真） ─────────────────────
check("三份源码都读到（WorkspaceView \(ws.count) 字 / Section \(sec.count) 字 / Kit \(kit.count) 字）",
      ws.count > 5000 && sec.count > 5000 && kit.count > 2000)

// ── 1. 挂点：工作台里恰好一处，且夹在「进行中」与「长期目标」之间 ──
check("工作台挂 WorkspaceProjectsSection 恰好 1 处",
      occurrences(ws, "WorkspaceProjectsSection(projects: projects, generatedAt: projectsGeneratedAt)") == 1)
check("挂点上挂了 .scrollDepth()（与其余块同档，漏挂 = 它不参与滚动层次）",
      ws.contains("WorkspaceProjectsSection(projects: projects, generatedAt: projectsGeneratedAt).scrollDepth()"))
if let iActive = ws.range(of: "activeCard.scrollDepth()"),
   let iProj = ws.range(of: "WorkspaceProjectsSection(projects: projects, generatedAt: projectsGeneratedAt).scrollDepth()"),
   let iGoal = ws.range(of: "GoalsSection().scrollDepth()") {
    check("顺序 = 进行中 → 进行项目 → 长期目标",
          iActive.lowerBound < iProj.lowerBound && iProj.lowerBound < iGoal.lowerBound)
} else {
    check("顺序 = 进行中 → 进行项目 → 长期目标（三处挂点都得在）", false)
}

// ── 2. 空态：没有项目就整块消失，不留空壳卡片 —— 且**不许**把生命周期押在 EmptyView 上 ──
// 🚨 v4.0.143 真机事故：`.task` 挂在「Group + 空态 EmptyView」→ 空态不插入渲染节点 →
//    回调永不触发 → 永远拉不到数据 → 整块永久消失（后端有数据、接口 200 也没用）。
// 现行口径 = 父级 loadProjects() 拉数据 + `if !projects.isEmpty` 门控（同 pendingItems）。
check("空态由父级门控（空就不进渲染树，不留空壳）",
      ws.contains("if !projects.isEmpty {\n                WorkspaceProjectsSection("))
check("🚫 卡片自己不再有 .task/load（生命周期不能再押在可能为空的视图上）",
      !sec.contains(".task {") && !sec.contains("func load()"))

// ── 3. 拉取失败保留旧快照（抖动不许显示成「一个项目都没有」） ──
check("fetchProjects 失败返回 nil（客户端保留旧数据）",
      kit.contains("func fetchProjects() async -> (projects: [QLProject], generatedAt: Int)?")
      && ws.contains("guard let r = await auth.fetchProjects() else { return }"))

// ── 4. 进度：有清单才画，没清单不编百分比 ────────────────────
check("进度块由 hasProgress 门控（无清单不画条）", sec.contains("if project.hasProgress { progressBlock }"))
check("进度条只用 progressFraction，不自己算 done/total",
      occurrences(sec, "progressFraction") == 1 && sec.contains("geo.size.width * project.progressFraction"))
check("无清单时 meta 行回落「本批标题」而不是 0%",
      sec.contains("} else if !p.batchTitle.isEmpty {"))

// ── 5. 数据源：只认 /api/agent/projects（lucky 白名单内） ─────
check("只调 /api/agent/projects（不写裸 /api/projects）",
      kit.contains("\"/api/agent/projects\"") && !kit.contains("\"/api/projects\""))
check("版本号不在客户端推算（Kit 里不该出现版本文件解析）",
      !kit.contains("MARKETING_VERSION") && !kit.contains("CURRENT_PROJECT_VERSION"))

// ── 6. 新鲜度：6 小时过期标记（不拿旧快照冒充实时） ──────────
check("staleAfter = 6 小时（单一真源）", kit.contains("static let staleAfter = 6 * 3600"))
check("卡头真有「数据可能过期」分支", sec.contains("if isStale {") && sec.contains("数据可能过期"))

// ── 7. 视觉口径：淡底走令牌、完成按钮在左 ────────────────────
check("淡底色不写字面量（0.14 / 0.15 全仓禁用）",
      !sec.contains("opacity(0.14)") && !sec.contains("opacity(0.15)"))
check("状态胶囊底走 Tint.coloredFill", sec.contains("Tint.coloredFill(scheme)"))
check("详情「完成」在 cancellationAction（全站弹窗口径）",
      sec.contains("ToolbarItem(placement: .cancellationAction)"))

// ── 8. 详情页四块齐全（进度/清单/更新/版本史）───────────────
check("详情含 清单 / 最近更新 / 版本历史 / 位置",
      sec.contains("blockTitle(\"清单\")") && sec.contains("blockTitle(\"最近更新\")")
      && sec.contains("blockTitle(\"版本历史\")") && sec.contains("blockTitle(\"位置\")"))

// ── 9. v4.0.143 栏目自定义：排序 + 隐藏（用户 2026-10-21「工作台也补齐各个栏目排序，隐藏自定义，对齐其他 tab」）──
let secEnum = src("qingliao/Features/Workspace/WorkspaceSection.swift")
check("工作台按 visibleSections 渲染（自定义顺序真生效，不是摆设）",
      ws.contains("ForEach(Array(visibleSections.enumerated()), id: \\.element)"))
check("顺序/隐藏各一条 AppStorage，key 与生活页 life_section_* 同族",
      ws.contains("@AppStorage(\"workspace_section_order\")") && ws.contains("@AppStorage(\"workspace_section_hidden\")"))
check("新栏目缺省补到末尾（老用户顺序串里没有 projects 也不会整块消失）",
      ws.contains("for s in WorkspaceSection.allCases where !seen.contains(s) { merged.append(s) }"))
check("隐藏只过滤渲染，不写数据（hiddenSections.filter 用 !contains）",
      ws.contains("orderedSections.filter { !h.contains($0) }"))
check("6 个栏目 case 齐全（待你处理/进行中/进行项目/长期目标/产物库/工具格）",
      ["pending", "active", "projects", "goals", "artifacts", "tools"]
        .allSatisfy { secEnum.contains("case \($0)") })
check("页底有「自定义栏目」入口（与生活页同款低调 pastelCard）",
      ws.contains("sectionEditorEntry") && ws.contains("自定义栏目（排序 / 隐藏）")
      && ws.contains(".tapButton { showSectionEditor = true }"))
check("编辑器写全量顺序串（shown + 隐藏项；只写 shown 会让隐藏项排好的位置丢失 = 生活页 SR13 的老坑）",
      secEnum.contains("let full = (shown + hiddenList)"))
check("编辑器有 ↑ / ↓ / eye.slash / 显示恢复",
      secEnum.contains("arrow.up") && secEnum.contains("arrow.down")
      && secEnum.contains("eye.slash") && secEnum.contains("Button(\"显示\")"))
check("编辑器「完成」在 cancellationAction（全站弹窗口径）",
      secEnum.contains("ToolbarItem(placement: .cancellationAction)"))

// ── 10. 产物库图片缩略图（v4.0.143 用户「现在只有文件名」） ────────────────
// 这一组的坏法同样编译不报：
//   ① 用 AsyncImage 直接拼下载 URL → 不带 X-Auth-Token，真机全灰（列表里一堆占位图）；
//   ② 把原图整张塞进内存 → 几十 MB 一张，滚动几屏就被系统杀掉；
//   ③ 每帧/每次滚动都重新下载 → 流量与卡顿双杀（必须有进程内缓存）；
//   ④ 行内自己判扩展名（跟 RemoteFiles.imageExts 两套真源）→ 以后加 heic/webp 只改一边。
let thumbSrc = src("qingliao/Features/Workspace/ArtifactThumbnail.swift")
check("缩略图组件存在（读不到 = 下面全是空真）", !thumbSrc.isEmpty)
check("产物行：图片走 ArtifactThumbnail，其余仍走图标 badge",
      ws.contains("if RemoteFiles.imageExts.contains(RemoteFiles.ext(f.name)) {")
      && ws.contains("ArtifactThumbnail(path: f.path)")
      && ws.contains("badge(iconName(f.name), tint: .accentColor)"))
check("产物行不自己写扩展名表（单一真源 RemoteFiles.imageExts）",
      !ws.contains("\"png\", \"jpg\"") && !ws.contains("case \"heic\""))
check("缩略图走 auth.downloadFile（自动带 X-Auth-Token / WiFi·蜂窝分流）",
      thumbSrc.contains("try await auth.downloadFile(path)"))
check("🚫 不用 AsyncImage 拼下载口（塞不进 header = 真机全灰）",
      !thumbSrc.contains("AsyncImage") && !thumbSrc.contains("/api/files/download"))
check("3x 下采样（几十 MB 原图不许整张进内存）",
      thumbSrc.contains("downscale(full, to: size * 3)")
      && thumbSrc.contains("UIGraphicsImageRenderer(size: newSize"))
check("进程内缓存（滚动/重进目录不重复下载）",
      thumbSrc.contains("NSCache<NSString, UIImage>()")
      && thumbSrc.contains("Self.cache.object(forKey: path as NSString)"))
check("非 200 不当成功图（后端 401/500 回 JSON，UIImage 解不出要显占位）",
      thumbSrc.contains("(200..<300).contains(code), let full = UIImage(data: data)"))

print("工作台「进行项目」真值表：\(passCount) 通过 / \(failCount) 失败")
if failCount > 0 { exit(1) }
