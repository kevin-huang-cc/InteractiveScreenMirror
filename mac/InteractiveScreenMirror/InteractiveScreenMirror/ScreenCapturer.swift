import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures one display and encodes it. One instance per virtual monitor.
final class ScreenCapturer: NSObject, SCStreamOutput {
    let streamID: UInt8
    private let displayID: CGDirectDisplayID
    private let fps: Int
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private var dropped = 0

    var onParameterSets: (UInt8, Data) -> Void = { _, _ in }
    var onFrame: (UInt8, Data, Bool) -> Void = { _, _, _ in }

    init(streamID: UInt8, displayID: CGDirectDisplayID, fps: Int) {
        self.streamID = streamID
        self.displayID = displayID
        self.fps = fps
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "ISM", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "display \(displayID) not visible to ScreenCaptureKit"])
        }

        let enc = try VideoEncoder(width: display.width, height: display.height, fps: fps)
        enc.onParameterSets = { [weak self] in
            guard let self else { return }
            self.onParameterSets(self.streamID, $0)
        }
        enc.onFrame = { [weak self] data, key in
            guard let self else { return }
            self.onFrame(self.streamID, data, key)
        }
        encoder = enc

        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // 3 is the SCK minimum for realtime. The previous 5 held ~83ms of
        // frames in front of the encoder for no benefit.
        cfg.queueDepth = 3
        cfg.showsCursor = true

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen,
                              sampleHandlerQueue: DispatchQueue(label: "ism.capture.\(streamID)"))
        try await s.startCapture()
        stream = s
    }

    func requestKeyframe() { encoder?.requestKeyframe() }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let enc = encoder else { return }
        // Drop rather than queue when the encoder is behind: a late frame is
        // worth less than a fresh one, and queueing only grows the lag.
        guard !enc.isBusy else {
            dropped += 1
            if dropped % 60 == 0 { NSLog("[ISM] stream \(streamID): dropped \(dropped) frames (encoder busy)") }
            return
        }
        enc.encode(pixelBuffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
