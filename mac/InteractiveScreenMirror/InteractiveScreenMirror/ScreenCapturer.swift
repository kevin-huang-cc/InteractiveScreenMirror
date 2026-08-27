import Foundation
import ScreenCaptureKit
import CoreMedia

final class ScreenCapturer: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private(set) var sourceWidth: Int = 0
    private(set) var sourceHeight: Int = 0

    var onParameterSets: (Data) -> Void = { _ in }
    var onFrame: (Data) -> Void = { _ in }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "ISM", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        sourceWidth = display.width
        sourceHeight = display.height

        let enc = try VideoEncoder(width: display.width, height: display.height)
        enc.onParameterSets = { [weak self] in self?.onParameterSets($0) }
        enc.onFrame = { [weak self] in self?.onFrame($0) }
        encoder = enc

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.queueDepth = 5
        cfg.showsCursor = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ism.capture"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder?.encode(pixelBuffer: pb, pts: pts)
    }
}
