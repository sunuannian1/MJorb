import SwiftUI

/// 美观的更新通知弹窗（毛玻璃卡片风格）
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let onDismiss: () -> Void
    @State private var wechatCopied = false

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
                    .padding(.bottom, 20)

                // 公众号引流区
                VStack(spacing: 8) {
                    Text("关注公众号「MJorb」获取最新动态")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(action: {
                        UIPasteboard.general.string = "MJorb"
                        wechatCopied = true
                        if let url = URL(string: "weixin://dl/profile?username=gh_3198ab620b01") {
                            UIApplication.shared.open(url)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            wechatCopied = false
                        }
                    }) {
                        Text(wechatCopied ? "已复制，正在跳转公众号" : "复制名称并打开公众号")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.sealAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.sealAccent.opacity(0.1))
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // 按钮区：去公众号下载 + 忽略此版本
                HStack(spacing: 10) {
                    Button(action: {
                        UIPasteboard.general.string = "MJorb"
                        wechatCopied = true
                        if let url = URL(string: "weixin://dl/profile?username=gh_3198ab620b01") {
                            UIApplication.shared.open(url)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            wechatCopied = false
                        }
                    }) {
                        Text(wechatCopied ? "已复制，跳转中" : "去公众号下载")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.sealAccent)
                            )
                    }
                    Button(action: onDismiss) {
                        Text("忽略此版本")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.sealSurfaceElevated)
                            )
                    }
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
