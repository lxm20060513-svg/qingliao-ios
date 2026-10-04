import Foundation

/// 待做池⑦「手写圈注发给 AI」的**纯逻辑真源**（不 import UIKit/SwiftUI → 可脱壳单测）。
///
/// 用户拍板范围 = 「只做图片圈注：选图 → 圈注 → 与原图一起发」（App 任务卡 f2bed7088e35 → 选项 1）。
///
/// 口径（全部收在这一处，View 只做接线）：
///  · 笔迹点一律**归一化到 0…1**（相对原图），**不存屏幕坐标** —— 换屏宽 / 横竖屏都对齐原图；
///  · 归一化基于「图片在画布里的等比适配矩形（aspect-fit）」→ 标注**不拉伸、不变形**；
///  · 撤销 = 弹出最后一笔；清空 = 全清；都不触碰已烘焙的图；
///  · 烘焙出的图长宽比恒等于原图（烘焙用原图尺寸渲染，见 `ImageAnnotateSheet.bake`）。
enum ImageAnnotation {

    /// 归一化点（构造即夹取到 0…1，越界不崩、不画到留白）
    struct Point: Equatable {
        var x: Double
        var y: Double
        init(_ x: Double, _ y: Double) {
            self.x = min(max(x, 0), 1)
            self.y = min(max(y, 0), 1)
        }
    }

    /// 一笔：点序列 + 调色板下标 + 笔宽比（笔宽 / 图片显示宽度 → 跨屏宽观感一致）
    struct Stroke: Equatable {
        var points: [Point]
        var colorIndex: Int
        var widthRatio: Double
    }

    /// 调色板容量（App 内唯一真源；View 的色数组条数必须与它相等，护栏钉死）
    static let paletteCount = 4

    /// 相邻落点最小归一化间距（去抖：一次拖动会产生海量亚像素点，全存会撑爆内存）
    static let minPointDistance = 0.004

    /// 落一个点：续上一笔；上一笔颜色/笔宽不同则**另起新一笔**（否则换色换粗细会串改历史笔画）。
    static func appending(_ strokes: [Stroke], point: Point,
                          colorIndex: Int, widthRatio: Double) -> [Stroke] {
        var out = strokes
        if var last = out.last,
           last.colorIndex == colorIndex,
           abs(last.widthRatio - widthRatio) < 1e-9 {
            if let prev = last.points.last {
                let dx = prev.x - point.x
                let dy = prev.y - point.y
                if dx * dx + dy * dy < minPointDistance * minPointDistance { return out }  // 去抖：太近不落
            }
            last.points.append(point)
            out[out.count - 1] = last
        } else {
            out.append(Stroke(points: [point], colorIndex: colorIndex, widthRatio: widthRatio))
        }
        return out
    }

    /// 撤销一笔（空数组安全返回空）
    static func undo(_ strokes: [Stroke]) -> [Stroke] {
        guard !strokes.isEmpty else { return strokes }
        return Array(strokes.dropLast())
    }

    /// 清空
    static func clear() -> [Stroke] { [] }

    static func isEmpty(_ strokes: [Stroke]) -> Bool { strokes.isEmpty }

    /// 画布里的图片等比适配矩形（aspect-fit，居中）。用 Double 宽高避开 CoreGraphics 依赖。
    /// 任一维 ≤ 0 → 返回零矩形（调用方据此判「几何还没量到」）。
    static func fitRect(contentW: Double, contentH: Double,
                        containerW: Double, containerH: Double)
        -> (x: Double, y: Double, w: Double, h: Double) {
        guard contentW > 0, contentH > 0, containerW > 0, containerH > 0 else {
            return (0, 0, 0, 0)
        }
        let scale = min(containerW / contentW, containerH / contentH)
        let w = contentW * scale
        let h = contentH * scale
        return ((containerW - w) / 2, (containerH - h) / 2, w, h)
    }

    /// 画布触点 → 归一化图片坐标；点落在图片矩形**之外**（留白）→ nil，不画到留白上
    static func normalize(canvasX: Double, canvasY: Double,
                          contentW: Double, contentH: Double,
                          containerW: Double, containerH: Double) -> Point? {
        let r = fitRect(contentW: contentW, contentH: contentH,
                        containerW: containerW, containerH: containerH)
        guard r.w > 0, r.h > 0 else { return nil }
        guard canvasX >= r.x, canvasX <= r.x + r.w,
              canvasY >= r.y, canvasY <= r.y + r.h else { return nil }
        return Point((canvasX - r.x) / r.w, (canvasY - r.y) / r.h)
    }

    /// 归一化点 → 指定矩形内的坐标（回显画布 / 烘焙原图共用一份映射 → 等比对齐不拉伸）
    static func denormalize(_ p: Point, inRect r: (x: Double, y: Double, w: Double, h: Double))
        -> (x: Double, y: Double) {
        (x: r.x + p.x * r.w, y: r.y + p.y * r.h)
    }
}
