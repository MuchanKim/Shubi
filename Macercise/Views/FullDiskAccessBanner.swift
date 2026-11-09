import SwiftUI

struct FullDiskAccessBanner: View {
    @State private var hasAccess = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // A stack, not a Group: a Group with no content has nothing to attach `onChange` to.
        VStack(spacing: 0) {
            if !hasAccess {
                VStack(alignment: .leading, spacing: Layout.Spacing.s) {
                    Label("전체 디스크 접근 권한", systemImage: "lock.fill")
                        .font(.callout.weight(.semibold))
                        .labelStyle(BannerLabelStyle())
                    Text("Safari 캐시와 앱 컨테이너를 보려면 필요해요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("설정 열기") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.Spacing.m)
                .background(.orange.quinary, in: .rect(cornerRadius: Layout.cornerRadius))
                .padding(Layout.Spacing.m)
            }
        }
        // Re-check when the user comes back from System Settings.
        .onChange(of: scenePhase, initial: true) { check() }
    }

    private func check() {
        hasAccess = FullDiskAccess.isGranted
    }
}

/// Orange lock, label-colored title.
private struct BannerLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Layout.Spacing.xs) {
            configuration.icon.foregroundStyle(.orange).accessibilityHidden(true)
            configuration.title
        }
    }
}
