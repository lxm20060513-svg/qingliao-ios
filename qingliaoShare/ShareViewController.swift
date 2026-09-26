import SwiftUI
import UIKit

/// 系统分享扩展的入口 VC。
/// `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`（见 project.yml）——
/// **不用 storyboard**：本仓没有 `MainInterface.storyboard`，用类名直挂更少一份要同步的资源。
///
/// 职责只有三件：① 把系统送来的 `NSExtensionItem` 交给模型；② 把 SwiftUI 卡片挂上来；
/// ③ 收尾（`completeRequest`）。
final class ShareViewController: UIViewController {

    private let model = ShareComposeModel()
    private var host: UIHostingController<ShareComposeView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 分享面板本身是系统的半透明材质：宿主视图必须透明，否则会盖出一块白/黑底把材质吃掉
        view.backgroundColor = .clear

        let root = ShareComposeView(model: model,
                                    onCancel: { [weak self] in self?.finish() },
                                    onFinish: { [weak self] in self?.finish() })
        let host = UIHostingController(rootView: root)
        // 高度交给 SwiftUI 自己算：`.preferredContentSize` 让宿主控制器把内容的固有高度报给系统，
        // 面板就按这个高度铺开 —— 不手写任何高度字面量，也不用 storyboard 的固定尺寸。
        host.sizingOptions = [.preferredContentSize]
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        // 「已交给轻聊」：先让用户看见这句，再收起面板（否则面板嗖地没了，用户以为没成功）
        model.onHandedOff = { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self?.finish()
            }
        }

        model.begin(with: extensionContext?.inputItems as? [NSExtensionItem] ?? [],
                    context: extensionContext)
    }

    /// 收尾统一走 `completeRequest(returningItems: nil)`。
    /// 不用 `cancelRequest(withError:)`：那会让系统在分享面板上弹一句错误提示，而用户什么也帮不上
    /// （「取消」和「知道了」对系统而言都是「这次分享结束了」）。
    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
