#if os(iOS)
import SwiftUI
import PrintDeckCore

struct FilesView: View {
    @Environment(PrinterStore.self) private var store
    @State private var search = ""

    var body: some View {
        let files = search.isEmpty ? store.files
            : store.files.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
        List(files) { f in
            NavigationLink(value: f) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.displayName).lineLimit(2)
                    Text("\(f.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if store.files.isEmpty {
                if store.filesLoading { ProgressView() }
                else { ContentUnavailableView("No files", systemImage: "folder", description: Text("G-code files on the printer appear here.")) }
            }
        }
        .navigationTitle("Files (\(store.files.count))")
        .navigationDestination(for: PrintFile.self) { FileDetailView(file: $0) }
        .searchable(text: $search)
        .refreshable { await store.refreshFiles() }
        .task { if store.files.isEmpty { await store.refreshFiles() } }
    }
}

struct FileDetailView: View {
    let file: PrintFile
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPrint = false

    var body: some View {
        let m = store.metadata[file.path]
        let busy = store.snapshot?.state.isActive == true
        Form {
            Section {
                HStack {
                    Spacer()
                    Thumbnail(url: store.thumbnailURL(for: file.path), size: 200)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section("Details") {
                if let t = m?.estimatedTime { LabeledContent("Estimated time", value: formatDuration(t)) }
                if let w = m?.filamentWeight { LabeledContent("Filament", value: String(format: "%.1f g", w)) }
                if let l = m?.layerCount { LabeledContent("Layers", value: "\(l)") }
                if let h = m?.objectHeight { LabeledContent("Height", value: String(format: "%.1f mm", h)) }
                if let s = m?.slicer { LabeledContent("Slicer", value: s) }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                LabeledContent("Uploaded", value: file.modified.formatted(date: .abbreviated, time: .shortened))
                if m == nil {
                    Text("The printer hasn't read this file's slicer details yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Print this file", systemImage: "printer.fill") { confirmPrint = true }
                    .disabled(busy || !store.connected)
            } footer: {
                if busy { Text("The printer is busy with another job.") }
            }
        }
        .navigationTitle(file.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadMetadata(file.path) }
        .confirmationDialog("Print \(file.displayName)?", isPresented: $confirmPrint, titleVisibility: .visible) {
            Button("Print") {
                store.startPrint(file.path)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Make sure the plate is clear and the right filament is loaded.") }
    }
}
#endif
