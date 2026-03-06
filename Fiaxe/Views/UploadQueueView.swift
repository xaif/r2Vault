import SwiftUI

struct UploadQueueView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        if viewModel.uploadTasks.isEmpty {
            emptyState
        } else {
            List(viewModel.uploadTasks) { task in
                UploadRowView(task: task)
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#else
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
#endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(Color.accentColor.opacity(0.06))
                    .frame(width: 72, height: 72)
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
            }

            VStack(spacing: 6) {
                Text("No Active Uploads")
                    .font(.title3.weight(.semibold))
                Text(emptyStateSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                viewModel.presentFilePicker()
            } label: {
                Label(emptyStateButtonTitle, systemImage: "arrow.up.circle.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var emptyStateSubtitle: String {
#if os(iOS)
        "Tap + to select files and upload them to R2."
#else
        "Choose files from your Mac and keep an eye on progress here while they upload to R2."
#endif
    }

    private var emptyStateButtonTitle: String {
#if os(iOS)
        "Upload Files"
#else
        "Upload Files..."
#endif
    }
}
