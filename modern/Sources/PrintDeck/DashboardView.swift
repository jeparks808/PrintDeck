#if os(iOS)
import SwiftUI
import Charts
import PrintDeckCore

struct DashboardView: View {
    @Environment(PrinterStore.self) private var store
    @State private var showConnect = false

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)]

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                if !store.connected, store.snapshot == nil {
                    ConnectingBanner()
                        .padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    Card { CameraView(url: store.cameraStream).clipShape(RoundedRectangle(cornerRadius: 10)) }
                    JobCard()
                    TemperatureCard()
                    ControlsCard()
                }
                .padding()
            }
            .background(Color(white: 0.06))
            .navigationTitle(store.client?.host ?? "PrintDeck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StatePill(state: store.state, connected: store.connected) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { FilesView() } label: { Label("Files", systemImage: "folder") }
                    Menu {
                        Button("Change printer…", systemImage: "printer") { showConnect = true }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
            .refreshable { await store.refreshFiles() }
            .sheet(isPresented: $showConnect) { ConnectView(onDone: { showConnect = false }) }
            .alert("The printer refused that", isPresented: Binding(get: { store.actionError != nil },
                                                               set: { if !$0 { store.actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.actionError ?? "") }
        }
    }
}

struct ConnectingBanner: View {
    @Environment(PrinterStore.self) private var store
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading) {
                Text("Connecting to \(store.address)…")
                if let e = store.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding()
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top)
    }
}

struct StatePill: View {
    let state: JobState
    let connected: Bool
    private var look: (String, Color) {
        guard connected else { return ("Offline", .gray) }
        return switch state {
        case .printing: ("Printing", .blue)
        case .paused: ("Paused", .yellow)
        case .complete: ("Finished", .green)
        case .error, .notReady: (state.label, .red)
        case .cancelled: ("Cancelled", .orange)
        default: (state.label, .green)
        }
    }

    var body: some View {
        let (text, color) = look
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(color)
            .overlay(Capsule().stroke(color, lineWidth: 1.5))
    }
}

/// A rounded dark panel, like the iPad app's cards.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: Job

struct JobCard: View {
    @Environment(PrinterStore.self) private var store
    @State private var confirmCancel = false

    var body: some View {
        let s = store.snapshot
        Card(title: s?.state.isActive == true ? "Current job" : "Job") {
            if let s, !s.filename.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Thumbnail(url: store.thumbnailURL(for: s.filename))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PrintFile(path: s.filename, modified: .now, size: 0).displayName)
                            .font(.headline).lineLimit(2)
                        Text(statusLine(s)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if s.state.isActive || s.state == .complete {
                        Text("\(Int((s.progress * 100).rounded(.down)))%")
                            .font(.system(size: 34, weight: .light).monospacedDigit())
                    }
                }
                if s.state.isActive {
                    ProgressView(value: s.progress).tint(.blue)
                    HStack {
                        if let l = s.currentLayer, let t = s.totalLayer, t > 0 { Text("Layer \(l) of \(t)") }
                        Spacer()
                        Text("Elapsed \(formatDuration(s.printDuration))")
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack {
                        if s.state == .paused {
                            Button("Resume", systemImage: "play.fill") { store.resume() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Pause", systemImage: "pause.fill") { store.pause() }
                                .buttonStyle(.bordered)
                        }
                        Button("Cancel", systemImage: "xmark", role: .destructive) { confirmCancel = true }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                    .disabled(store.actionRunning)
                }
                if !s.message.isEmpty, s.state != .printing {
                    Text(s.message).font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(store.connected ? "Nothing printing. Start a print from Files." : "—")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Cancel this print?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel print", role: .destructive) { store.cancel() }
            Button("Keep printing", role: .cancel) {}
        } message: { Text("The printer stops and the job can't be resumed.") }
    }

    private func statusLine(_ s: PrinterSnapshot) -> String {
        switch s.state {
        case .printing, .paused:
            guard let left = store.remaining else { return s.state.label }
            let finish = Date().addingTimeInterval(left).formatted(date: .omitted, time: .shortened)
            return "\(formatDuration(left)) left · done ≈ \(finish)"
        case .complete: return "Finished in \(formatDuration(s.printDuration))"
        case .cancelled: return "Cancelled after \(formatDuration(s.printDuration))"
        default: return s.state.label
        }
    }
}

struct Thumbnail: View {
    let url: URL?
    var size: CGFloat = 64
    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "cube").font(.title2).foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Temperatures

enum HeaterKind: String, Identifiable {
    case nozzle, bed
    var id: String { rawValue }
    var title: String { self == .nozzle ? "Nozzle" : "Bed" }
    var presets: [Int] { self == .nozzle ? [0, 190, 210, 220, 240, 260] : [0, 55, 60, 70, 80, 100] }
    var maximum: Int { self == .nozzle ? 300 : 120 }
}

struct TemperatureCard: View {
    @Environment(PrinterStore.self) private var store
    @State private var editing: HeaterKind?

    var body: some View {
        let s = store.snapshot
        Card(title: "Temperatures") {
            HStack(spacing: 10) {
                TempTile(name: "Nozzle", value: s?.nozzle?.temperature, target: s?.nozzle?.target, color: .orange) { editing = .nozzle }
                TempTile(name: "Bed", value: s?.bed?.temperature, target: s?.bed?.target, color: .red) { editing = .bed }
                if s?.chamber != nil || store.objects.chamberSensor != nil {
                    TempTile(name: "Chamber", value: s?.chamber, target: nil, color: .cyan, action: nil)
                }
            }
            Chart {
                ForEach(store.history) { p in
                    if let v = p.nozzle {
                        LineMark(x: .value("Time", p.time), y: .value("°C", v), series: .value("Heater", "Nozzle"))
                            .foregroundStyle(.orange)
                    }
                    if let v = p.bed {
                        LineMark(x: .value("Time", p.time), y: .value("°C", v), series: .value("Heater", "Bed"))
                            .foregroundStyle(.red)
                    }
                    if let v = p.chamber {
                        LineMark(x: .value("Time", p.time), y: .value("°C", v), series: .value("Heater", "Chamber"))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
            Text("Last \(Int(store.historySpan / 60)) minutes. Tap the nozzle or bed to set a temperature.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .sheet(item: $editing) { kind in TargetSheet(kind: kind).presentationDetents([.medium]) }
    }
}

struct TempTile: View {
    let name: String
    let value: Double?
    let target: Double?
    let color: Color
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption).foregroundStyle(.secondary)
                Text(value.map { String(format: "%.0f°", $0) } ?? "–")
                    .font(.system(size: 30, weight: .light).monospacedDigit())
                    .foregroundStyle(heating ? color : .primary)
                Text(target.map { $0 > 0 ? String(format: "→ %.0f°", $0) : "off" } ?? "no heater")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private var heating: Bool { (target ?? 0) > 0 }
}

struct TargetSheet: View {
    let kind: HeaterKind
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var custom = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))]) {
                        ForEach(kind.presets, id: \.self) { t in
                            Button(t == 0 ? "Off" : "\(t)°") { set(t) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                Section("Custom") {
                    Stepper("\(custom)°", value: $custom, in: 0...kind.maximum, step: 5)
                    Button("Set \(custom)°") { set(custom) }
                }
            }
            .navigationTitle("\(kind.title) temperature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                let cur = kind == .nozzle ? store.snapshot?.nozzle?.target : store.snapshot?.bed?.target
                custom = Int(cur ?? 0)
            }
        }
    }

    private func set(_ t: Int) {
        if kind == .nozzle { store.setNozzle(t) } else { store.setBed(t) }
        dismiss()
    }
}

// MARK: Fans, light, speed

struct ControlsCard: View {
    @Environment(PrinterStore.self) private var store

    private let speeds: [(String, Int)] = [("Silent", 50), ("Balanced", 100), ("Sport", 130), ("Ludicrous", 160)]

    var body: some View {
        let s = store.snapshot
        Card(title: "Fans, light and speed") {
            if let v = s?.partFan {
                FanRow(name: "Part", value: v) { store.setPartFan($0) }
            }
            if let name = store.objects.auxFan, let v = s?.auxFan {
                FanRow(name: "Aux", value: v) { store.setFan(name, $0) }
            }
            if let name = store.objects.caseFan, let v = s?.caseFan {
                FanRow(name: "Case", value: v) { store.setFan(name, $0) }
            }
            if let on = s?.lightOn {
                Toggle("Case light", isOn: Binding(get: { on }, set: { store.setLight($0) }))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Print speed \(Int(((s?.speedFactor ?? 1) * 100).rounded()))%").font(.subheadline)
                HStack(spacing: 6) {
                    ForEach(speeds, id: \.1) { name, pct in
                        let current = Int(((s?.speedFactor ?? 1) * 100).rounded()) == pct
                        Button(name) { store.setSpeed(pct) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(current ? .orange : .gray)
                    }
                }
            }
        }
        .disabled(!store.connected)
    }
}

/// A fan with a slider. The printer is only told when you let go.
struct FanRow: View {
    let name: String
    let value: Double
    let set: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack {
            Text(name).frame(width: 50, alignment: .leading)
            Slider(value: Binding(get: { dragging ?? value }, set: { dragging = $0 }), in: 0...1, step: 0.05) { editing in
                if !editing, let d = dragging { set(d); dragging = nil }
            }
            Text("\(Int(((dragging ?? value) * 100).rounded()))%")
                .font(.callout.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }
}
#endif
