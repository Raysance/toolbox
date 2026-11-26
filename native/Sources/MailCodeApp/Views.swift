import SwiftUI
import MailCodeCore

typealias ViewState<Value> = SwiftUI.State<Value>

struct ToastView: View {
    let event: CodeEvent
    @ViewState var copied: Bool
    let copy: () -> Bool
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.provider)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(event.account).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { copied = copy() } label: {
                Text(event.code).font(.system(size: 22, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: event.code.count > 8 ? 126 : 98, alignment: .trailing)
            }.buttonStyle(.plain).help(copied ? "已复制 · 点击重新复制" : "复制验证码")
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }.buttonStyle(.plain).help("关闭")
        }
        .padding(.horizontal, 12).frame(width: 340, height: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08), lineWidth: 0.5))
    }
}
