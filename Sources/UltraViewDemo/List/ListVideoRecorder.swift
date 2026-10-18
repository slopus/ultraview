#if canImport(UIKit)
import AVFoundation
import CoreMedia
import QuartzCore
import UIKit

/// Demo-only screen recording for device QA (`-listRecord YES`).
///
/// A display link draws the app's windows into a reduced-size buffer on main
/// and hands it to an H.264 writer on a background queue. `hierarchy` uses
/// `drawHierarchy(afterScreenUpdates: false)`, which shows what is on screen,
/// animations included; `layers` renders the presentation layer tree, which is
/// cheaper but omits system materials. Neither captures the keyboard: it is
/// drawn by another process. When `overlay` supplies a rectangle (the
/// keyboard layout guide), it is filled with a marked gray band so the video
/// shows where the app believes the keyboard is.
///
/// ReplayKit would capture the whole screen off main, but every capture
/// session raises a system consent alert that outlives the app, so an
/// unattended device can't use it.
@MainActor
final class ListVideoRecorder: NSObject {
    enum Method: String { case hierarchy, layers }
    struct Frame { var time: Double; var callback: Double; var mainMilliseconds: Double }

    let method: Method
    let pixelsPerPoint: Double
    let interval: Int
    var overlay: (() -> CGRect?)?
    private(set) var frames: [Frame] = []
    private(set) var outputSize = CGSize.zero
    private var encoder: VideoFileEncoder?
    private var link: CADisplayLink?
    private var pool: CVPixelBufferPool?
    private var callbacks = 0
    private var lastTime = -Double.infinity
    private let url: URL

    init(url: URL, method: Method, pixelsPerPoint: Double, interval: Int) {
        self.url = url; self.method = method; self.pixelsPerPoint = pixelsPerPoint; self.interval = max(1, interval)
    }

    func start(screen: UIScreen) {
        // H.264 needs even dimensions.
        func even(_ points: Double) -> Double { (points * pixelsPerPoint / 2).rounded() * 2 }
        let size = CGSize(width: even(screen.bounds.width), height: even(screen.bounds.height))
        outputSize = size
        encoder = VideoFileEncoder(url: url, width: Int(size.width), height: Int(size.height))
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, attributes as CFDictionary, &created)
        pool = created
        let link = CADisplayLink(target: self, selector: #selector(capture(_:)))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); self.link = link
    }

    @objc private func capture(_ link: CADisplayLink) {
        let callback = CACurrentMediaTime()
        callbacks += 1
        guard callbacks % interval == 0, link.timestamp > lastTime, let pool, let encoder else { return }
        lastTime = link.timestamp
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: pixelsPerPoint, y: -pixelsPerPoint)
            UIGraphicsPushContext(context)
            for window in Self.windows() {
                switch method {
                case .hierarchy: window.drawHierarchy(in: window.frame, afterScreenUpdates: false)
                case .layers:
                    context.saveGState(); context.translateBy(x: window.frame.minX, y: window.frame.minY)
                    (window.layer.presentation() ?? window.layer).render(in: context)
                    context.restoreGState()
                }
            }
            if let band = overlay?(), band.height > 0.5 {
                context.setFillColor(gray: 0.55, alpha: 1); context.fill(band)
                context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                context.fill(CGRect(x: band.minX, y: band.minY, width: band.width, height: 2 / pixelsPerPoint))
            }
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = link.timestamp
        frames.append(.init(time: time, callback: callback, mainMilliseconds: (CACurrentMediaTime() - callback) * 1000))
        let box = PixelBufferBox(buffer: buffer)
        encoder.queue.async { encoder.append(box.buffer, time: time) }
    }

    /// The app's visible windows, back to front.
    static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    static func windowDescriptions() -> [[String: Any]] {
        windows().map { ["class": String(describing: type(of: $0)), "level": Double($0.windowLevel.rawValue), "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }
    }

    /// Stops capture and waits for the file to be written.
    func stop() async -> VideoFileEncoder.Result {
        link?.invalidate(); link = nil
        guard let encoder else { return .init(appended: 0, dropped: 0, error: "not started") }
        return await encoder.finish()
    }
}

/// A pixel buffer handed to the encoder queue. The display link never touches
/// it again after the hand-off, so only the queue uses it.
private struct PixelBufferBox: @unchecked Sendable { let buffer: CVPixelBuffer }

/// Owns the asset writer. Every mutable member is used only on `queue`
/// (`finish` hops onto it), which is the reason it may cross threads.
final class VideoFileEncoder: @unchecked Sendable {
    struct Result: Sendable { var appended: Int; var dropped: Int; var error: String? }
    let queue = DispatchQueue(label: "dev.ultraview.demo.video-encoder", qos: .userInitiated)
    private let url: URL, width: Int, height: Int
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastTime = -Double.infinity
    private var appended = 0, dropped = 0
    private var failure: String?

    init(url: URL, width: Int, height: Int) {
        self.url = url; self.width = width; self.height = height
    }

    private func prepare(at time: CMTime) -> Bool {
        if writer != nil { return writer?.status == .writing }
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: width * height * 16, AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoAllowFrameReorderingKey: false, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            writer.add(input)
            guard writer.startWriting() else { failure = writer.error?.localizedDescription ?? "startWriting"; return false }
            writer.startSession(atSourceTime: time)
            self.writer = writer; self.input = input; self.adaptor = adaptor
            return true
        } catch {
            failure = error.localizedDescription; return false
        }
    }

    /// On `queue`. Presentation times are display-link timestamps, so gaps in
    /// the file are gaps in capture.
    func append(_ buffer: CVPixelBuffer, time: Double) {
        guard time > lastTime else { return }
        let presentation = CMTime(seconds: time, preferredTimescale: 1_000_000)
        guard prepare(at: presentation), let input, let adaptor, input.isReadyForMoreMediaData else { dropped += 1; return }
        if adaptor.append(buffer, withPresentationTime: presentation) { appended += 1; lastTime = time } else { dropped += 1 }
    }

    func finish() async -> Result {
        await withCheckedContinuation { (done: CheckedContinuation<Result, Never>) in
            queue.async { [self] in
                guard let writer, let input, writer.status == .writing else {
                    done.resume(returning: .init(appended: appended, dropped: dropped, error: failure ?? self.writer?.error?.localizedDescription ?? "not writing"))
                    return
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTime(seconds: lastTime, preferredTimescale: 1_000_000))
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        done.resume(returning: .init(appended: appended, dropped: dropped, error: self.writer?.error?.localizedDescription))
                    }
                }
            }
        }
    }
}
#endif
