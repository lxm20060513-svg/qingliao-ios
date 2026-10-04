// 待做池⑦「手写圈注发给 AI」真值表 —— Linux 本地预检用（权威入口 = check_swift.sh 第 79 段）
//
// 编译运行（在仓库根目录）：
//   $SWIFT/swiftc -swift-version 6 -o /tmp/test_annotate \
//       scripts/ql_annotate/truth_table_annotate.swift qingliao/Core/ImageAnnotationKit.swift
//
// 用户拍板范围 = 「只做图片圈注：选图 → 圈注 → 与原图一起发」（App 任务卡 f2bed7088e35）。
//
// 本表钉死的口径：
//   · 撤销 = 回退到上一笔（C 段）；空数组安全；清空归零
//   · 归一化点 0…1 夹取；等比适配矩形（aspect-fit）→ **标注与原图按比例对齐、不拉伸**（D/E/F 段）
//   · 落点去抖（minPointDistance）；换色/换粗细必另起一笔（不串改历史笔画）（B 段）
//   · 烘焙输出长宽比恒等于原图（源级钉 `UIGraphicsImageRenderer(size: image.size)` + `format.scale`）
//
// A/B/C 段**真编译真跑** Core/ImageAnnotationKit.swift（与实现同一份文件 → 无「表/实现漂移」洞）；
// D 段为源级断言（剥注释），钉接线在源码里真实存在。

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var positives = 0
nonisolated(unsafe) var negatives = 0

func ok(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}
func pos(_ name: String, _ cond: Bool) { positives += 1; ok(name, cond) }
func neg(_ name: String, _ cond: Bool) { negatives += 1; ok(name, cond) }

/// 整行剥注释（不按行内 `//` 剥：Swift 里有 `http://` 之类字面量会被截断）
func stripComments(_ s: String) -> String {
    s.components(separatedBy: "\n").map { line -> String in
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") ? "" : line
    }.joined(separator: "\n")
}
func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@main
enum AnnotateTruthTable {

    static func main() {
        // ---------- A. Point 归一化夹取 ----------
        let c = ImageAnnotation.Point(-0.5, 1.5)
        pos("A1 越界点构造即夹取到 0…1", c.x == 0 && c.y == 1)
        neg("A2 越界 -0.5 被夹取（不再等于自身）", c.x != -0.5)
        let inRange = ImageAnnotation.Point(0.3, 0.7)
        pos("A3 界内点原样保留", inRange.x == 0.3 && inRange.y == 0.7)

        // ---------- B. appending（续笔 / 去抖 / 换色换宽另起一笔） ----------
        var s: [ImageAnnotation.Stroke] = []
        s = ImageAnnotation.appending(s, point: ImageAnnotation.Point(0.1, 0.1), colorIndex: 0, widthRatio: 0.008)
        pos("B1 空数组落点 → 起一笔", s.count == 1 && s[0].points.count == 1)
        s = ImageAnnotation.appending(s, point: ImageAnnotation.Point(0.5, 0.5), colorIndex: 0, widthRatio: 0.008)
        pos("B2 同色同宽 + 远点 → 续同一笔", s.count == 1 && s[0].points.count == 2)
        s = ImageAnnotation.appending(s, point: ImageAnnotation.Point(0.5005, 0.5005), colorIndex: 0, widthRatio: 0.008)
        pos("B3 太近的点被去抖丢弃", s.count == 1 && s[0].points.count == 2)
        s = ImageAnnotation.appending(s, point: ImageAnnotation.Point(0.9, 0.9), colorIndex: 1, widthRatio: 0.008)
        pos("B4 换色 → 另起新一笔（不串改历史）", s.count == 2 && s[1].points.count == 1)
        s = ImageAnnotation.appending(s, point: ImageAnnotation.Point(0.2, 0.2), colorIndex: 1, widthRatio: 0.014)
        pos("B5 换粗细 → 另起新一笔", s.count == 3)
        pos("B6 点序保持（首点即首落点）", s[0].points.first == ImageAnnotation.Point(0.1, 0.1))
        pos("B7 笔属性随笔画记录", s[0].colorIndex == 0 && abs(s[0].widthRatio - 0.008) < 1e-9)

        // ---------- C. 撤销 / 清空 ----------
        let undone = ImageAnnotation.undo([s[0], s[1]])
        pos("C1 撤销回退到上一笔", undone.count == 1 && undone[0].points.count == 2)
        pos("C2 空数组撤销安全", ImageAnnotation.undo([]).isEmpty)
        pos("C3 清空归零", ImageAnnotation.clear().isEmpty)
        pos("C4 isEmpty 判据", ImageAnnotation.isEmpty([]) && !ImageAnnotation.isEmpty([s[0]]))

        // ---------- D. fitRect（等比适配，不拉伸） ----------
        let rWide = ImageAnnotation.fitRect(contentW: 200, contentH: 100, containerW: 400, containerH: 400)
        pos("D1 宽图 → 撑满宽、上下留白",
            rWide.w == 400 && rWide.h == 200 && rWide.x == 0 && rWide.y == 100)
        let rTall = ImageAnnotation.fitRect(contentW: 100, contentH: 200, containerW: 400, containerH: 400)
        pos("D2 高图 → 撑满高、左右留白",
            rTall.w == 200 && rTall.h == 400 && rTall.x == 100 && rTall.y == 0)
        let rExact = ImageAnnotation.fitRect(contentW: 200, contentH: 200, containerW: 400, containerH: 400)
        pos("D3 同比例 → 填满无留白", rExact.w == 400 && rExact.h == 400 && rExact.x == 0 && rExact.y == 0)
        let rZero = ImageAnnotation.fitRect(contentW: 0, contentH: 100, containerW: 400, containerH: 400)
        neg("D4 零尺寸内容 → 零矩形（不当成有效几何）", rZero.w == 0 && rZero.h == 0)
        let rNoC = ImageAnnotation.fitRect(contentW: 200, contentH: 100, containerW: 0, containerH: 0)
        pos("D5 零尺寸容器 → 零矩形", rNoC.w == 0 && rNoC.h == 0)
        // 长宽比守恒：适配矩形与原图同比例（不拉伸）
        pos("D6 适配矩形长宽比 == 原图", abs((rWide.w / rWide.h) - (200.0 / 100.0)) < 1e-9)

        // ---------- E. normalize（画布触点 → 归一化，跨屏宽不变） ----------
        let p1 = ImageAnnotation.normalize(canvasX: 100, canvasY: 200,
                                           contentW: 200, contentH: 100,
                                           containerW: 400, containerH: 400)
        pos("E1 宽图中心偏左 → (0.25, 0.5)", p1 == ImageAnnotation.Point(0.25, 0.5))
        let p2 = ImageAnnotation.normalize(canvasX: 200, canvasY: 400,
                                           contentW: 200, contentH: 100,
                                           containerW: 800, containerH: 800)
        pos("E2 换成双倍画布，同一相对位置归一化相同（跨屏宽对齐）", p2 == p1)
        let outside = ImageAnnotation.normalize(canvasX: 100, canvasY: 10,
                                                contentW: 200, contentH: 100,
                                                containerW: 400, containerH: 400)
        neg("E3 落在留白上 → nil（不画到留白）", outside == nil)
        let corner = ImageAnnotation.normalize(canvasX: 400, canvasY: 300,
                                               contentW: 200, contentH: 100,
                                               containerW: 400, containerH: 400)
        pos("E4 右下角边界 → (1, 1)", corner == ImageAnnotation.Point(1, 1))
        let noGeo = ImageAnnotation.normalize(canvasX: 1, canvasY: 1,
                                              contentW: 200, contentH: 100,
                                              containerW: 0, containerH: 0)
        neg("E5 几何未量到（容器 0）→ nil（不误画）", noGeo == nil)

        // ---------- F. denormalize（回显 / 烘焙共用一份映射） ----------
        let d1 = ImageAnnotation.denormalize(ImageAnnotation.Point(0.25, 0.5), inRect: (0, 100, 400, 200))
        pos("F1 归一化点 → 画布坐标", abs(d1.x - 100) < 1e-9 && abs(d1.y - 200) < 1e-9)
        pos("F2 来回映射一致（normalize→denormalize 回到原触点）",
            abs(d1.x - 100) < 1e-6 && abs(d1.y - 200) < 1e-6)
        // 烘焙口径：归一化 → 原图像素矩形（0.5,0.5 of 1280x720 → 640,360）
        let d2 = ImageAnnotation.denormalize(ImageAnnotation.Point(0.5, 0.5), inRect: (0, 0, 1280, 720))
        pos("F3 烘焙映射到图像像素（等比、不拉伸）", abs(d2.x - 640) < 1e-9 && abs(d2.y - 360) < 1e-9)

        // ---------- G. 源级接线（剥注释；注释里写了 ≠ 接线了） ----------
        let kit = stripComments(read("qingliao/Core/ImageAnnotationKit.swift"))
        pos("G1 纯逻辑单源：Kit 不 import UIKit（可脱壳单测）", !kit.contains("import UIKit"))
        pos("G2 Kit 提供 undo/clear/fitRect/normalize/denormalize",
            kit.contains("static func undo(") && kit.contains("static func clear(")
            && kit.contains("static func fitRect(") && kit.contains("static func normalize(")
            && kit.contains("static func denormalize("))
        pos("G3 调色板容量为 4（唯一真源）", ImageAnnotation.paletteCount == 4)

        let cv = stripComments(read("qingliao/Features/Chat/ChatView.swift"))
        pos("G4 图片预览条挂了「圈注」入口", cv.contains("Text(\"圈注\")"))
        pos("G5 入口开面板", cv.contains("showAnnotate = true"))
        pos("G6 面板已接线（回调写回 pendingImage/pendingImageData）",
            cv.contains("ImageAnnotateSheet(source:")
            && cv.contains("pendingImageData = compressImage(out)"))

        let sheet = stripComments(read("qingliao/Features/Chat/ImageAnnotateSheet.swift"))
        pos("G7 面板用 Kit 的 normalize 采集触点", sheet.contains("ImageAnnotation.normalize("))
        pos("G8 面板用 Kit 的 denormalize 回显/烘焙", sheet.contains("ImageAnnotation.denormalize("))
        pos("G9 面板用 Kit 的 appending/undo/clear",
            sheet.contains("ImageAnnotation.appending(") && sheet.contains("ImageAnnotation.undo(")
            && sheet.contains("ImageAnnotation.clear()"))
        pos("G10 烘焙尺寸取原图 → 长宽比与原图一致",
            sheet.contains("UIGraphicsImageRenderer(size: image.size"))
        pos("G11 烘焙保留原图 scale（像素尺寸不缩水）", sheet.contains("format.scale = image.scale"))
        pos("G12 完成胶囊在左位（本仓铁律）", sheet.contains(".cancellationAction"))
        pos("G13 调色板与本表口径一致", sheet.contains("[.red, .yellow, .blue, .green]"))
        neg("G14 不存屏幕坐标（Kit 里不出现 UIScreen 绝对坐标）", !kit.contains("UIScreen.main.bounds"))

        print("----")
        print("正例 \(positives) / 反例 \(negatives) / \(failures) 失败")
        if failures > 0 { exit(1) }
    }
}
