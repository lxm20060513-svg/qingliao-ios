import SwiftUI

// MARK: - 启动动画（轻聊风格：聊天气泡 + 环境光晕，自然简洁一次淡入，无复杂粒子）

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            // 环境光晕（与 Dock 同款：蓝/靛/青底部光）
            ZStack {
                Circle().fill(Color.blue.opacity(0.16)).frame(width: 300, height: 300).blur(radius: 70)
                    .offset(y: 260)
                Circle().fill(Color.indigo.opacity(0.10)).frame(width: 240, height: 240).blur(radius: 60)
                    .offset(x: 150, y: 220)
                Circle().fill(Color.cyan.opacity(0.07)).frame(width: 220, height: 220).blur(radius: 55)
                    .offset(x: -150, y: 230)
            }

            VStack(spacing: 0) {
                // 聊天气泡 logo + 呼吸光晕
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(appeared ? 0.22 : 0.4))
                        .frame(width: 170, height: 170)
                        .blur(radius: 30)
                        .scaleEffect(appeared ? 1.35 : 0.7)
                        .opacity(appeared ? 0 : 0.7)

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .shadow(color: Color.blue.opacity(0.5), radius: 22, y: 6)
                }
                .scaleEffect(appeared ? 1 : 0.72)
                .opacity(appeared ? 1 : 0)

                // 标题
                VStack(spacing: 6) {
                    Text("轻聊")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("QINGLIAO · AI Agent")
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
