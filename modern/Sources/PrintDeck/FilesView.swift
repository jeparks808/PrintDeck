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
        .searchable(text: $search)
        .refreshable { await store.refreshFiles() }
        .task { if store.files.isEmpty { await store.refreshFiles() } }
    }
}

extension Color {
    /// "#RRGGBB" → Color.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
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
                if let n = m?.nozzleDiameter { LabeledContent("Nozzle", value: String(format: "%.1f mm", n)) }
                if let h = m?.layerHeight { LabeledContent("Layer height", value: String(format: "%.2f mm", h)) }
                if let t = m?.firstLayerNozzle, let b = m?.firstLayerBed {
                    LabeledContent("First layer", value: String(format: "%.0f° nozzle · %.0f° bed", t, b))
                }
                if let s = m?.slicer { LabeledContent("Slicer", value: s) }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                LabeledContent("Uploaded", value: file.modified.formatted(date: .abbreviated, time: .shortened))
                if m == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Asking the printer to read this file…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let filaments = m?.filaments, !filaments.isEmpty {
                Section("Filament") {
                    ForEach(Array(filaments.enumerated()), id: \.offset) { i, f in
                        HStack(spacing: 10) {
                            Circle().fill(Color(hex: f.color) ?? .gray).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.white.opacity(0.3)))
                            Text(filaments.count > 1 ? "\(i + 1)" : "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(f.name ?? f.type ?? "Filament").lineLimit(1)
                            Spacer()
                            if let t = f.type { Text(t).foregroundStyle(.secondary) }
                        }
                    }
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
