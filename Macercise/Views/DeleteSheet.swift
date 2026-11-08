import SwiftUI

struct DeleteSheet: View {
    let items: [ScanItem]
    /// Some scans failed, so items they would have found aren't in `items`.
    var missesFailedScans = false
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Cleaner.Mode.trash
    @State private var removesLeftovers = false
    @State private var confirmPermanent = false
    @State private var isDeleting = false
    @State private var current: String?
    @State private var failures: [Cleaner.Failure] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.Spacing.l) {
            if failures.isEmpty {
                VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                    Text("\(items.count)개 항목 정리").font(.title3.bold())
                    Text("합계 \(items.reduce(0) { $0 + $1.size }.formatted(.byteCount(style: .file)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if missesFailedScans {
                        Label("일부 항목을 스캔하지 못해 목록에서 빠졌어요", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                // The caller rescans after a delete, so `items` may already be the new scan here.
                Label("\(failures.count)개 항목을 지우지 못했어요", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.red)
            }

            Group {
                if failures.isEmpty {
                    List(items) { item in
                        HStack(spacing: Layout.Spacing.s) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path(percentEncoded: false)))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.size, format: .byteCount(style: .file))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    List(failures) { failure in
                        VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                            Text(failure.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(failure.reason).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(height: Layout.sheetListHeight)

            if failures.isEmpty {
                let commandCount = items.filter { $0.command != nil }.count
                if commandCount > 0 {
                    Label("\(commandCount)개 항목은 휴지통을 거치지 않고 바로 지워져요.",
                          systemImage: "terminal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                let leftoverCount = items.reduce(0) { $0 + $1.leftovers.count }
                if leftoverCount > 0 {
                    // Off by default: a notes app keeps its only copy of the user's documents in this data.
                    Toggle(isOn: $removesLeftovers) {
                        VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                            Text("앱이 남긴 데이터도 지우기 (\(leftoverCount)곳)")
                            Text("노트처럼 앱 안에 저장한 문서도 함께 지워져요.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isDeleting)
                }
                Picker("삭제 방식", selection: $mode) {
                    Text("휴지통으로 이동").tag(Cleaner.Mode.trash)
                    Text("영구 삭제").tag(Cleaner.Mode.permanent)
                }
                .pickerStyle(.segmented)
                .disabled(isDeleting)
                if mode == .trash && commandCount < items.count {
                    Text("휴지통을 비워야 디스크 공간이 생겨요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("취소", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isDeleting)
                    // No Return shortcut: command items are removed for good even in trash mode.
                    Button("삭제", role: .destructive) {
                        if mode == .permanent { confirmPermanent = true } else { run() }
                    }
                    .disabled(isDeleting)
                }
            } else {
                HStack {
                    Spacer()
                    Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Layout.pageMargin)
        .frame(width: Layout.sheetWidth)
        .overlay {
            if isDeleting {
                ProgressView(current.map { String(localized: "\($0) 정리 중…") } ?? "")
                    .padding(Layout.cardPadding)
                    .background(.regularMaterial, in: .rect(cornerRadius: Layout.cornerRadius))
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .confirmationDialog("영구 삭제한 항목은 되돌릴 수 없어요.", isPresented: $confirmPermanent) {
            Button("영구 삭제", role: .destructive) { run() }
        }
    }

    private func run() {
        isDeleting = true
        // Fixed here: the mode the user confirmed applies to every item.
        let mode = mode
        let removesLeftovers = removesLeftovers
        Task {
            var result: [Cleaner.Failure] = []
            // One at a time, so the sheet can say which item a slow command (brew cleanup) is on.
            for item in items {
                current = item.name
                result += await Task.detached { Cleaner.clean([item], mode: mode, removesLeftovers: removesLeftovers) }.value
            }
            isDeleting = false
            onDeleted()
            if result.isEmpty { dismiss() } else { failures = result }
        }
    }
}
