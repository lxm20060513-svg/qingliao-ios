import SwiftUI

// MARK: - 启动动画（轻聊风格：聊天气泡 + 环境光晕，自然简洁一次淡入，无复杂粒子）

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            // 环境光晕（与 Dock 同款：蓝/靛/青底部光）
            ZStack {
                Circle().fill(Color.blue.opacity(Tint.soft)).frame(width: 300, height: 300).blur(radius: 70)
                    .offset(y: 260)
                Circle().fill(Color.indigo.opacity(Tint.faint)).frame(width: 240, height: 240).blur(radius: 60)
                    .offset(x: 150, y: 220)
                Circle().fill(Color.cyan.opacity(Tint.faint)).frame(width: 220, height: 220).blur(radius: 55)
                    .offset(x: -150, y: 230)
            }

            VStack(spacing: 0) {
                // v4.0.x：logo 换正式图标资产（卡片叠层立体 Q，与 AppIcon 同款）
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(appeared ? 0.22 : 0.4))
                        .frame(width: 170, height: 170)
                        .blur(radius: 30)
                        .scaleEffect(appeared ? 1.35 : 0.7)
                        .opacity(appeared ? 0 : 0.7)

                    Image("AboutLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .shadow(color: Color.blue.opacity(0.35), radius: 18, y: 6)
                }
                // v4.0.76：logo 整体调小（用户反馈三处统一口径，见 LoginView）
                .scaleEffect(appeared ? 1 : 0.72)
                .opacity(appeared ? 1 : 0)

                // 标题
                VStack(spacing: 6) {
                    // v4.0.70：轻聊正式更名 Qimo（用户 2026-10-07 拍板）——中文语境写全名「Qimo（轻聊）」，
                    // 英文名 Qimo；桌面图标名走本地化（中文仍「轻聊」/ 英文「Qimo」，见 qingliao/en.lproj/InfoPlist.strings）
                    Text("Qimo（轻聊）")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("AI AGENT")
                        .font(.system(size: Typography.subhead, weight: .medium))
                        .foregroundStyle(.secondary)
                        .tracking(3)
                }
                .offset(y: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
                .padding(.top, 26)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.85, bounce: 0.22)) {
                appeared = true
            }
        }
    }
}
