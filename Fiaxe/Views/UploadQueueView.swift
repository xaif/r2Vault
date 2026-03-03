import SwiftUI

struct UploadQueueView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        if viewModel.uploadTasks.isEmpty {
            ContentUnavailableView {
                Label("No Active Uploads", systemImage: "arrow.up.circle")
            } description: {
                Text("Click + to select files and upload them to R2.")
            } actions: {
                Button {
                    viewModel.presentFilePicker()
                } label: {
                    Label("Upload Files…", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List(viewModel.uploadTasks) { task in
                UploadRowView(task: task)
            }
            .listStyle(.inset)
        }
    }
}
