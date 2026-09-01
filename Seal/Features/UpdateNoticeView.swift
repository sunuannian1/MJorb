import SwiftUI

/// 美观的更新通知弹窗（毛玻璃卡片风格）
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // 半透明背景
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)

            // 卡片
            VStack(spacing: 0) {
                // 图标
                Image(uiImage: UIImage(named: "AppIcon") ?? UIImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 28)
                    .padding(.bottom, 16)

                // 标题
                Text(notice.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 6)

                // 版本号
                Text("新版本 \(notice.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)

                // 内容
                Text(notice.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                // 按钮
                Button(action: onDismiss) {
                    Text("知道了")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.sealAccent)
                        )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 12)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}
