import SwiftUI

/// 查找. Placeholder until Task 19: back and the search field.
struct SearchScreen: View {
    let onBack: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                BackButton(action: onBack)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    TextField("", text: $query)
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.text)
                        .focused($focused)
                        .submitLabel(.search)
                        .accessibilityLabel("查找")
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .frame(height: Metrics.hit)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line, lineWidth: 1))
            }
            .padding(EdgeInsets(top: 12, leading: Metrics.gutter, bottom: 12, trailing: Metrics.gutter))
            .frame(minHeight: 76)
            Spacer()
        }
        .background(Palette.bg.ignoresSafeArea())
        .task {
            try? await Task.sleep(for: .milliseconds(440))
            focused = true
        }
    }
}
