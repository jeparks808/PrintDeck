#if os(iOS)
import SwiftUI
import UIKit
import PrintDeckCore

/// Plays an MJPEG stream (the printer's webcam). Reconnects when the stream drops, and stops when the view goes away.
@MainActor @Observable
final class MJPEGPlayer {
    private(set) var image: UIImage?
    private(set) var fps: Double = 0
    private(set) var failed = false

    private var url: URL?
    private var session: URLSession?
    private var receiver: Receiver?
    private var frameTimes: [Date] = []
    private var retry: Task<Void, Never>?

    func play(_ url: URL?) {
        guard url != self.url || session == nil else { return }
        stop()
        self.url = url
        guard let url else { return }
        let r = Receiver()
        r.onFrame = { [weak self] data in
            guard let img = UIImage(data: data) else { return }
            Task { @MainActor in self?.show(img) }
        }
        r.onEnd = { [weak self] in Task { @MainActor in self?.ended() } }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = .infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: config, delegate: r, delegateQueue: nil)
        receiver = r
        session = s
        s.dataTask(with: url).resume()
    }

    func stop() {
        retry?.cancel()
        retry = nil
        session?.invalidateAndCancel()
        session = nil
        receiver = nil
        url = nil
    }

    private func show(_ img: UIImage) {
        image = img
        failed = false
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        fps = Double(frameTimes.count) / 2
    }

    private func ended() {
        guard let url else { return }
        failed = image == nil
        session?.invalidateAndCancel()
        session = nil
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.play(url)
        }
    }

    /// URLSession delegate: splits the byte stream into JPEG frames off the main thread.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var splitter = MJPEGSplitter()
        var onFrame: ((Data) -> Void)?
        var onEnd: (() -> Void)?
        private var lastDelivered = Date.distantPast

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let frames = splitter.append(data)
            // Only the newest frame matters; skip the rest if the stream outruns the screen (max ~20 fps).
            guard let last = frames.last, Date().timeIntervalSince(lastDelivered) > 0.05 else { return }
            lastDelivered = Date()
            onFrame?(last)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            onEnd?()
        }
    }
}

struct CameraView: View {
    let url: URL?
    var showsFPS = true
    @State private var player = MJPEGPlayer()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.black)
            if let img = player.image {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: player.failed ? "video.slash" : "video")
                        .font(.largeTitle)
                    Text(url == nil ? "No camera" : player.failed ? "Camera not answering" : "Connecting to the camera…")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
            if showsFPS, player.image != nil {
                Text(String(format: "%.0f fps", player.fps))
                    .font(.caption2.monospacedDigit())
                    .padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .onAppear { player.play(url) }
        .onChange(of: url) { _, new in player.play(new) }
        .onDisappear { player.stop() }
    }
}
#endif
