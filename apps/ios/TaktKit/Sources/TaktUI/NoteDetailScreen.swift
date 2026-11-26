import SwiftUI

/// One note. Placeholder until Task 18: header with the title, and 「提取」 while there is no draft.
@available(iOS 26, macOS 26, *)
struct NoteDetailScreen: View {
    @Bindable var detail: NoteDetailModel
    let onBack: () -> Void

    private var title: String {
        guard let n = detail.note else { return "" }
        return NoteLanguage.title(n.title, createdAt: n.createdAt)
    }

    private var canExtract: Bool {
        guard let n = detail.note else { return false }
        return !detail.isLocalOnly && n.hasTranscript && n.extraction.chains.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BackButton(action: onBack)
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 12, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
            .frame(minHeight: 76)
            ZStack {
                if canExtract {
                    Button { Task { await detail.extract() } } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                Image(systemName: "sparkles").opacity(detail.extracting ? 0 : 1)
                                if detail.extracting { ProgressView().tint(Palette.onFill) }
                            }
                            .frame(width: 20, height: 20)
                            Text("提取")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.onFill)
                        .padding(.leading, 20)
                        .padding(.trailing, 24)
                        .frame(minHeight: 52)
                        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                    }
                    .buttonStyle(.plain)
                    .disabled(detail.extracting)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.fade, value: canExtract)
        }
        .background(Palette.bg.ignoresSafeArea())
    }
}
