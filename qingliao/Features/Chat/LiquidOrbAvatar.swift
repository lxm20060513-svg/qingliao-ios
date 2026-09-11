//  AI 头像（siri 液态玻璃球）
//
//  渲染器与 Metal 着色器来自开源项目 lersent001/orb（MIT License, Copyright (c) 2026 LerSent001），
//  由该项目自带的 SwiftUI 导出器生成，轻聊侧改动仅 4 处（见文件内 v3.9.2 注释）：
//    1. 删掉内嵌 76KB Metal 字符串 → 编译期 default.metallib（CI 可提前发现 MSL 错误）
//    2. device/queue/三条管线提取为进程级共享单例（原来每个头像各建一套）
//    3. 静止态冻结（isPaused + 按需重绘）、思考态 30fps（原模板恒 60fps）
//    4. 初始化失败不再 preconditionFailure（降级为不显示，不让 App 崩）
//  完整许可见 docs/THIRD_PARTY_LICENSES.md

import Foundation
import MetalKit
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

private let orbIdleUniformSeed: [Float] = [
    1, 1, 0, 0.2460000067949295, 0.7200000286102295, 0.3384000062942505, 1.6640000343322754, 0.23999999463558197,
    1.9800000190734863, 0.11999999731779099, 0.2800000011920929, 0.23999999463558197, 0.18000000715255737, 0.18000000715255737, 1.3600000143051147, 9,
    0.004999999888241291, 0, 0, 1, 0.4399999976158142, 0, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    0.7098039388656616, 0.6509804129600525, 0.45490196347236633, 1, 0.3686274588108063, 0.529411792755127, 0.5803921818733215, 1,
    0.6039215922355652, 0.3921568691730499, 0.5411764979362488, 1, 0.38823530077934265, 0.35686275362968445, 0.5411764979362488, 1,
    0.7137255072593689, 0.7686274647712708, 0.8235294222831726, 1, 1, 1, 1, 1,
    0.6078431606292725, 0.95686274766922, 1, 1, 0.772549033164978, 0.6627451181411743, 1, 1,
    0.9176470637321472, 0.95686274766922, 1, 1, 0.8627451062202454, 0.9176470637321472, 1, 1,
    0.0117647061124444, 0.01568627543747425, 0.03529411926865578, 1, 0.42352941632270813, 0.40784314274787903, 0.5607843399047852, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]

private let orbThinkingUniformSeed: [Float] = [
    1, 1, 0, 0.8199999928474426, 0.7200000286102295, 0.36000001430511475, 3.200000047683716, 0.5,
    2.200000047683716, 0.11999999731779099, 0.2800000011920929, 0.23999999463558197, 0.18000000715255737, 0.18000000715255737, 2, 9,
    0.004999999888241291, 0, 0, 1, 0.4399999976158142, 0, 2, 0.41999998688697815,
    0.7699999809265137, 0.23000000417232513, 65, 0, 0, 1, 0.2199999988079071, 0.25,
    0.7200000286102295, 5, 0.41999998688697815, 1.25, 0.550000011920929, 0.30000001192092896, 1.2000000476837158, 0.699999988079071,
    1, 0.8470588326454163, 0.41960784792900085, 1, 0.5098039507865906, 0.95686274766922, 1, 1,
    1, 0.48235294222831726, 0.8352941274642944, 1, 0.5568627715110779, 0.42352941632270813, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1,
    0.6078431606292725, 0.95686274766922, 1, 1, 0.772549033164978, 0.6627451181411743, 1, 1,
    0.9176470637321472, 0.95686274766922, 1, 1, 0.8627451062202454, 0.9176470637321472, 1, 1,
    0.0117647061124444, 0.01568627543747425, 0.03529411926865578, 1, 0.5843137502670288, 0.42352941632270813, 1, 1,
    0.9686274528503418, 0.9843137264251709, 1, 1, 0.9372549057006836, 0.9647058844566345, 0.9921568632125854, 1,
    0.8784313797950745, 0.9333333373069763, 0.9764705896377563, 1, 0.8313725590705872, 0.9019607901573181, 0.9686274528503418, 1,
    0.7333333492279053, 0.8352941274642944, 0.9529411792755127, 1, 0.6509804129600525, 0.7803921699523926, 0.9411764740943909, 1,
    0.529411792755127, 0.6901960968971252, 0.9215686321258545, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
    0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1, 0.43529412150382996, 0.6196078658103943, 0.9098039269447327, 1,
]

/// v3.9.4：球体半径（= uniforms[4]，上游导出默认 0.72）。
/// 球径 = 该值 × 头像格边长：0.72 时球只占头像格的 72%。原先外面套的蓝色渐变底圆是 100%，
/// 用户去掉底圆后球显得变小 → 按用户要求放大到 0.98，让球径≈头像格（观感与原来的底圆尺寸对齐）。
/// 说明：放大只是「缩放」——球内所有内容都按 p = uv / contourRad 归一化，内部观感不变；
/// 边缘光晕（edgeSoftness=0.005 / edgeGlow=0）留 2% 余量，不会被裁。
private let orbBallRadius: Float = 0.98

private let orbActivationDuration: CFTimeInterval = 0.22
private let orbSettleDuration: CFTimeInterval = 0.65
private let orbRibbonStyleIndex: Float = 24
private let orbRibbonInstanceCount = 221184

public enum LiquidOrbState: Sendable {
    case idle
    case thinking
}

private func orbUniformSeed(for state: LiquidOrbState) -> [Float] {
    var seed: [Float]
    switch state {
    case .idle: seed = orbIdleUniformSeed
    case .thinking: seed = orbThinkingUniformSeed
    }
    // v3.9.4：球体半径改为统一常量（去底圆后按用户要求放大，见 orbBallRadius 说明）。
    // 上游导出里 idle/thinking 两套 seed 的 [4] 都是 0.72，这里统一覆写，方便日后一处调参。
    if seed.count > 4 { seed[4] = orbBallRadius }
    return seed
}

private func orbSrgbToLinear(_ value: Float) -> Float {
    value <= 0.04045
        ? value / 12.92
        : Float(pow(Double((value + 0.055) / 1.055), 2.4))
}

private func orbLinearToSrgb(_ value: Float) -> Float {
    value <= 0.0031308
        ? value * 12.92
        : 1.055 * Float(pow(Double(value), 1.0 / 2.4)) - 0.055
}

private func orbMixSrgb(_ from: Float, _ to: Float, _ progress: Float) -> Float {
    orbLinearToSrgb(
        orbSrgbToLinear(from) + (orbSrgbToLinear(to) - orbSrgbToLinear(from)) * progress
    )
}

private enum LiquidOrbError: Error {
    case metalUnavailable
    case shaderFunctionMissing(String)
    case commandQueueUnavailable
}

/// v3.9.2：进程级共享资源——device / commandQueue / 三条管线只建一次。
/// 原模板每个 renderer 各建一套：聊天列表里每条 AI 消息的头像都会重复建 3 个 pipeline state。
/// v3.9.2：Swift 6 严格并发下，非 Sendable 类型的 static let 会报错；
/// 内部状态由 NSLock 保护（同上仓 HangWatchdog / ImageCache 的写法）。
private final class LiquidOrbShared: @unchecked Sendable {
    struct Resources {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let ribbonPipeline: MTLRenderPipelineState
        let ribbonCompositePipeline: MTLRenderPipelineState
    }

    static let shared = LiquidOrbShared()

    private var cached: Resources?
    private let lock = NSLock()

    func resources() throws -> Resources {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LiquidOrbError.metalUnavailable
        }
        // 编译期 Metal：LiquidOrbEffect.metal 随 App 编译进 default.metallib。
        // 原模板用 device.makeLibrary(source:) 运行时编译 —— 那样 MSL 写错只有真机才炸，
        // 编译期版本让 CI 的 Archive 就能提前报错。
        guard let library = device.makeDefaultLibrary() else {
            throw LiquidOrbError.shaderFunctionMissing("default library")
        }
        guard let vertex = library.makeFunction(name: "vs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("vs_main")
        }
        guard let fragment = library.makeFunction(name: "fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("fs_main")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = LiquidOrbShared.pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        guard let ribbonVertex = library.makeFunction(name: "ribbon_vs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("ribbon_vs_main")
        }
        guard let ribbonFragment = library.makeFunction(name: "ribbon_fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("ribbon_fs_main")
        }
        let ribbonDescriptor = MTLRenderPipelineDescriptor()
        ribbonDescriptor.vertexFunction = ribbonVertex
        ribbonDescriptor.fragmentFunction = ribbonFragment
        ribbonDescriptor.colorAttachments[0].pixelFormat = LiquidOrbShared.pixelFormat
        ribbonDescriptor.colorAttachments[0].isBlendingEnabled = true
        ribbonDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        ribbonDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        ribbonDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        ribbonDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let ribbonPipeline = try device.makeRenderPipelineState(descriptor: ribbonDescriptor)

        guard let ribbonCompositeFragment = library.makeFunction(name: "ribbon_composite_fs_main") else {
            throw LiquidOrbError.shaderFunctionMissing("ribbon_composite_fs_main")
        }
        let ribbonCompositeDescriptor = MTLRenderPipelineDescriptor()
        ribbonCompositeDescriptor.vertexFunction = vertex
        ribbonCompositeDescriptor.fragmentFunction = ribbonCompositeFragment
        ribbonCompositeDescriptor.colorAttachments[0].pixelFormat = LiquidOrbShared.pixelFormat
        ribbonCompositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        ribbonCompositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        ribbonCompositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        ribbonCompositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        ribbonCompositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let ribbonCompositePipeline = try device.makeRenderPipelineState(
            descriptor: ribbonCompositeDescriptor
        )

        guard let queue = device.makeCommandQueue() else {
            throw LiquidOrbError.commandQueueUnavailable
        }
        let resources = Resources(
            device: device,
            queue: queue,
            pipeline: pipeline,
            ribbonPipeline: ribbonPipeline,
            ribbonCompositePipeline: ribbonCompositePipeline
        )
        cached = resources
        return resources
    }

    /// 全仓统一 bgra8Unorm（MTKView 的 colorPixelFormat 与管线必须一致）
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
}

/// v3.9.2：@MainActor —— MTKView 是 UIKit 子类（主 actor 隔离），
/// 原模板在非隔离上下文里直接写 view.device/isPaused，Swift 6 下编译不过。
/// MTKView 的 delegate 回调本来就在主线程（CADisplayLink）。
@MainActor
private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let ribbonPipeline: MTLRenderPipelineState
    private let ribbonCompositePipeline: MTLRenderPipelineState
    private var ribbonTexture: MTLTexture?
    private var lastFrameAt = CACurrentMediaTime()
    private var motionPhase: CFTimeInterval = 0
    private let stateLock = NSLock()
    private var currentState: LiquidOrbState
    private var transitionTargetState: LiquidOrbState
    private var fromUniforms: [Float]
    private var targetUniforms: [Float]
    private var displayedUniforms: [Float]
    private var transitionStartedAt = CACurrentMediaTime()
    private var activeTransitionDuration: CFTimeInterval = 0
    /// v3.9.2：用于静止态「播完过渡就冻结」
    private weak var view: MTKView?
    private var pauseTask: Task<Void, Never>?
    private var pacingState: LiquidOrbState?
    private var hasDrawnFrame = false

    init(view: MTKView, state: LiquidOrbState) throws {
        let initialUniforms = orbUniformSeed(for: state)
        currentState = state
        transitionTargetState = state
        fromUniforms = initialUniforms
        targetUniforms = initialUniforms
        displayedUniforms = initialUniforms

        let resources = try LiquidOrbShared.shared.resources()
        view.device = resources.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30   // v3.9.2：本仓约定 30fps（模板原为 60）
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        #if os(iOS)
        view.isOpaque = false
        #elseif os(macOS)
        view.layer?.isOpaque = false
        #endif
        view.clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )

        // v3.9.2：复用进程级共享资源（device/queue/三条管线）
        pipeline = resources.pipeline
        ribbonPipeline = resources.ribbonPipeline
        ribbonCompositePipeline = resources.ribbonCompositePipeline
        commandQueue = resources.queue
        self.view = view
        super.init()
    }

    /// v3.9.2 功耗策略：思考中连续 30fps；静止态先把回落过渡（settleDuration）播完，
    /// 然后 isPaused + 按需重绘冻成一张静态图 —— 列表里几十个静止头像不产生任何连续 GPU 开销。
    func updatePacing(for state: LiquidOrbState, animated: Bool) {
        guard let view else { return }
        // v3.9.2：状态没变就直接返回 —— SwiftUI 每次 body 重算都会调 updateUIView（流式 token 约 100ms 一次），
        // 无条件重置会把刚冻结的静止头像重新唤醒跑 30fps，正好抵消掉"静止态零 GPU 开销"的省电设计。
        guard pacingState != state else { return }
        pacingState = state
        pauseTask?.cancel()
        pauseTask = nil
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        guard state == .idle else { return }
        // animated=false 时用最短延迟：等 SwiftUI 布局把 drawableSize 落定后再冻结，
        // 否则首帧被 drawableSize == 0 挡掉、冻结后永远不再重绘 → 头像空白
        let delay = animated ? orbSettleDuration + 0.12 : 0.18
        pauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let view = self.view else { return }
            // v3.9.2：首帧真画出来之前不许冻结（冷启动/首屏繁忙时 drawableSize 可能还没落定），最多补等 ~0.8s
            var waited = 0
            while !self.hasDrawnFrame && waited < 8 {
                try? await Task.sleep(for: .seconds(0.1))
                if Task.isCancelled { return }
                waited += 1
            }
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay()
        }
    }

    /// v3.9.2：静止态补一帧（回前台/图层内容被系统回收后调用）
    func refreshIfPaused() {
        guard let view, view.isPaused else { return }
        view.setNeedsDisplay()
    }

    func setState(_ state: LiquidOrbState) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state != currentState else { return }

        let nextUniforms = orbUniformSeed(for: state)
        fromUniforms = sampleTransition(at: now)
        targetUniforms = nextUniforms
        transitionTargetState = state
        transitionStartedAt = now
        activeTransitionDuration = state == .thinking
            ? orbActivationDuration
            : orbSettleDuration
        currentState = state
    }

    private func sampleTransition(at now: CFTimeInterval) -> [Float] {
        let rawProgress = activeTransitionDuration == 0
            ? 1
            : min(1, max(0, (now - transitionStartedAt) / activeTransitionDuration))
        let easedProgress = transitionTargetState == .thinking
            ? 1 - pow(1 - rawProgress, 3)
            : rawProgress * rawProgress * (3 - 2 * rawProgress)
        let progress = Float(easedProgress)

        for index in 3..<displayedUniforms.count {
            let isColorComponent = index >= 40
                && (index - 40) % 4 < 3
            displayedUniforms[index] = isColorComponent
                ? orbMixSrgb(fromUniforms[index], targetUniforms[index], progress)
                : fromUniforms[index] + (targetUniforms[index] - fromUniforms[index]) * progress
        }
        return displayedUniforms
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        ribbonTexture = nil
        // v3.9.2：静止态下布局/旋转导致尺寸变化要补画一帧，否则图层内容是空的
        if view.isPaused { view.setNeedsDisplay() }
    }

    private func ensureRibbonTexture(for view: MTKView) -> MTLTexture? {
        let width = max(1, Int(view.drawableSize.width))
        let height = max(1, Int(view.drawableSize.height))
        if let ribbonTexture,
           ribbonTexture.width == width,
           ribbonTexture.height == height {
            return ribbonTexture
        }
        guard let device = view.device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: view.colorPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        ribbonTexture = device.makeTexture(descriptor: descriptor)
        return ribbonTexture
    }

    func draw(in view: MTKView) {
        guard
            view.drawableSize.width > 0,
            view.drawableSize.height > 0,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        stateLock.lock()
        var uniforms = sampleTransition(at: now)
        stateLock.unlock()
        let frameDelta = min(0.1, max(0, now - lastFrameAt))
        lastFrameAt = now
        motionPhase += frameDelta * CFTimeInterval(max(uniforms[3], 0))
        uniforms[0] = Float(view.drawableSize.width)
        uniforms[1] = Float(view.drawableSize.height)
        uniforms[2] = Float(motionPhase / CFTimeInterval(max(uniforms[3], 0.001)))
        let isParticleRibbon = round(uniforms[15]) == orbRibbonStyleIndex
        if isParticleRibbon {
            guard let ribbonTexture = ensureRibbonTexture(for: view) else { return }
            let ribbonPass = MTLRenderPassDescriptor()
            ribbonPass.colorAttachments[0].texture = ribbonTexture
            ribbonPass.colorAttachments[0].loadAction = .clear
            ribbonPass.colorAttachments[0].storeAction = .store
            ribbonPass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0
            )
            guard let ribbonEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: ribbonPass
            ) else { return }
            ribbonEncoder.setRenderPipelineState(ribbonPipeline)
            uniforms.withUnsafeBytes { bytes in
                ribbonEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                ribbonEncoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            ribbonEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: orbRibbonInstanceCount
            )
            ribbonEncoder.endEncoding()
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(isParticleRibbon ? ribbonCompositePipeline : pipeline)
        uniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        if isParticleRibbon {
            encoder.setFragmentTexture(ribbonTexture, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        hasDrawnFrame = true   // v3.9.2：给静止态冻结任务一个"至少画过一帧"的判据
        // 注：ribbon 通道（ribbonPipeline / ribbonCompositePipeline / ensureRibbonTexture）
        // 只在 style == particleRibbon(24) 时走；本头像用的 siri 流向索引 = 9，恒不触发。
        // 保留是刻意与上游导出保持逐行同构（将来换样式即可用），不是遗漏。
    }
}

@MainActor
private final class LiquidOrbCoordinator {
    private var renderer: LiquidOrbRenderer?
    /// v3.9.2 摘通知用的观察者 token。
    /// `nonisolated(unsafe)`：Swift 6 里 **deinit 恒为 nonisolated**，而 `any NSObjectProtocol` 非 Sendable，
    /// 普通 @MainActor 存储属性在 deinit 里访问会报
    /// "cannot access property 'foregroundObserver' with a non-Sendable type ... from nonisolated deinit"（CI 实证）。
    /// token 只在「注册（主 actor）」与「deinit 摘除」两处访问、自身无共享可变状态，故 unsafe 是安全的。
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?

    /// v3.9.2：MTKView 冻结后图层内容是"最后一帧"，进后台可能被系统回收 —— 回前台补画一帧，
    /// 免得静止头像变空白（没有这步只能等用户滚动/切页才恢复）
    private func observeForeground() {
        #if os(iOS)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshIfPaused()
        }
        #endif
    }

    func makeView(state: LiquidOrbState) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
        do {
            let renderer = try LiquidOrbRenderer(view: view, state: state)
            self.renderer = renderer
            view.delegate = renderer
            renderer.updatePacing(for: state, animated: false)
            observeForeground()
            return view
        } catch {
            // v3.9.2：原模板是 preconditionFailure —— 侧载 App 不该因为头像渲染器初始化失败直接崩，
            // 失败就只是这个头像空白（外层还有渐变圆兜底），并留 NSLog 便于真机诊断。
            NSLog("[轻聊] LiquidOrb 初始化失败，头像降级: \(error)")
            return view
        }
    }

    func setState(_ state: LiquidOrbState) {
        renderer?.setState(state)
        renderer?.updatePacing(for: state, animated: true)
    }

    func refreshIfPaused() {
        renderer?.refreshIfPaused()
    }

    deinit {
        // v3.9.2：NotificationCenter 会永久持有 block —— 不摘除的话每个回收的头像都留一个僵尸观察者，
        // 长列表滚动后每次进前台会触发 N 次空调用。
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }
}

#if os(iOS)
private struct LiquidOrbSurface: UIViewRepresentable {
    let state: LiquidOrbState

    func makeCoordinator() -> LiquidOrbCoordinator { LiquidOrbCoordinator() }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView(state: state) }
    func updateUIView(_ view: MTKView, context: Context) { context.coordinator.setState(state) }
}
#elseif os(macOS)
private struct LiquidOrbSurface: NSViewRepresentable {
    let state: LiquidOrbState

    func makeCoordinator() -> LiquidOrbCoordinator { LiquidOrbCoordinator() }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView(state: state) }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.setState(state) }
}
#endif

/// v3.9.2：头像渲染器可用性（Metal 设备/着色器函数缺失时降级）。
/// 判据只算一次（首次访问时建管线，约几毫秒）；进程内所有头像共用。
enum LiquidOrbAvailability {
    private static let cached: Bool = {
        do {
            _ = try LiquidOrbShared.shared.resources()
            return true
        } catch {
            NSLog("[轻聊] LiquidOrb 不可用，AI 头像降级为图标: \(error)")
            return false
        }
    }()

    static var isAvailable: Bool { cached }
}

/// 轻聊 AI 头像：用 lersent001/orb 的 siri 液态玻璃球（MIT）。
/// - 思考中 → thinking 态，30fps 连续动画
/// - 不思考 → idle 态静态帧（播完回落过渡后冻结，不产生连续 GPU 开销）
struct LiquidOrbAvatar: View {
    var size: CGFloat = 30
    var thinking: Bool = false

    var body: some View {
        if LiquidOrbAvailability.isAvailable {
            LiquidOrbView(state: thinking ? .thinking : .idle)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            // v3.9.2 兜底：渲染器不可用（极少见）时退回脑形标
            // v3.9.4：调用方已不再画蓝色底圆（用户要求去掉），这里自带底圆保证白脑标可见
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "brain.head.profile")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

public struct LiquidOrbView: View {
    private let state: LiquidOrbState

    public init(state: LiquidOrbState = .thinking) {
        self.state = state
    }

    public var body: some View {
        LiquidOrbSurface(state: state)
    }
}