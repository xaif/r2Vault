import SwiftUI

struct UploadHistoryView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        if viewModel.historyStore.items.isEmpty {
            ContentUnavailableView {
                Label("No Upload History", systemImage: "clock")
            } description: {
                Text("Completed uploads will appear here.")
            } actions: {
                Button {
                    viewModel.presentFilePicker()
                } label: {
                    Label("Upload Files…", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(viewModel.historyStore.items) { item in
                    HistoryRowView(item: item)
                }
                .onDelete { offsets in
                    viewModel.historyStore.remove(at: offsets)
                }
            }
            .listStyle(.inset)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(role: .destructive) {
                        viewModel.historyStore.clearAll()
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                }
            }
        }
    }
}
