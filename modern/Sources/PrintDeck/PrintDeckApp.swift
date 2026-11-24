#if os(iOS)
import SwiftUI

@main
struct PrintDeckApp: App {
    @State private var store = PrinterStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.hasPrinter { DashboardView() } else { ConnectView() }
            }
            .environment(store)
            .preferredColorScheme(.dark)
            .tint(.orange)
        }
        .onChange(of: phase) { _, p in
            // Poll only while the app is on screen.
            if p == .active { store.start() } else { store.stop() }
        }
    }
}

/// First run (or "Change printer"): ask for the printer's address and check it answers.
struct ConnectView: View {
    @Environment(PrinterStore.self) private var store
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?
    var onDone: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.0.185", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("Printer address")
                } footer: {
                    Text("The printer's IP address or name on your Wi-Fi. PrintDeck talks to Klipper printers through Moonraker, such as a Centauri Carbon running OpenCentauri COSMOS. Add a port if it isn't 80, for example printer.local:7125.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    Button(action: connect) {
                        HStack {
                            Text("Connect")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                }
            }
            .navigationTitle("PrintDeck")
            .onAppear { if address.isEmpty { address = store.address } }
        }
    }

    private func connect() {
        checking = true
        error = nil
        Task {
            do {
                try await store.connect(to: address)
                onDone?()
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
        }
    }
}
#endif
