import AVKit
import UIKit

/// 画中画待机小窗：小窗可见时系统给 App 挂 PIPVisible，后台可按需开麦。内容为 VoiceKey 图标 + 状态
final class PiPStandby: NSObject {
    /// App 在后台时小窗被关掉、被系统收回或没能自动打开
    var onLost: ((String) -> Void)?
    /// 前台启动小窗失败
    var onFailed: ((String) -> Void)?

    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private(set) var running = false
    private var wanted = false
    private var pending = false
    private var restoring = false
    private var retrying = false
    private var label = "待命"
    private let display = AVSampleBufferDisplayLayer()
    private let host = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 18))
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    private var deadline: DispatchWorkItem?
    private static let size = CGSize(width: 480, height: 270)

    override init() {
        super.init()
        display.frame = host.bounds
        display.videoGravity = .resizeAspect
        host.layer.addSublayer(display)
        host.isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, self.wanted, !self.running, UIApplication.shared.applicationState == .background else { return }
                self.onLost?("not running in background")
            }
        }
    }

    /// 打开小窗（须在前台）；窗口还没建好时等下次回到前台再开
    func start() {
        wanted = true
        guard !running, attach() else {
            if !running { Bus.log("pip: no window yet") }
            return
        }
        if controller == nil {
            let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: display, playbackDelegate: self))
            c.delegate = self
            c.canStartPictureInPictureAutomaticallyFromInline = true
            c.requiresLinearPlayback = true
            controller = c
            possible = c.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.kick() }
            }
        }
        draw()
        pending = true
        deadline?.cancel()
        let d = DispatchWorkItem { [weak self] in
            guard let self, self.pending else { return }
            self.pending = false
            self.onFailed?("start timeout possible=\(self.controller?.isPictureInPicturePossible ?? false)")
        }
        deadline = d
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: d)
        kick()
    }

    func stop() {
        wanted = false
        pending = false
        deadline?.cancel()
        possible = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
        controller = nil
        running = false
        display.flushAndRemoveImage()
        host.removeFromSuperview()
    }

    /// 更新小窗里的状态文字
    func show(_ text: String) {
        guard text != label else { return }
        label = text
        if controller != nil { draw() }
    }

    private func kick() {
        guard pending, let c = controller, !c.isPictureInPictureActive else { return }
        // 从键盘跳过来时 App 还在 inactive，这时开会报 -1001，等 active 再开
        if c.isPictureInPicturePossible, UIApplication.shared.applicationState == .active {
            Bus.log("pip: start")
            c.startPictureInPicture()
        }
        // 首帧解码前 startPictureInPicture 会静默失败（status 0），没起来就隔一会儿再试，直到超时
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.retrying = false
            guard self.pending, !self.running else { return }
            self.kick()
        }
    }

    /// 内容层须在窗口里，放在最底层不挡界面
    private func attach() -> Bool {
        if host.window != nil { return true }
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let w else { return false }
        w.insertSubview(host, at: 0)
        return true
    }

    // MARK: 画面

    private func draw() {
        guard let buf = Self.sample(Self.image(label)) else { return Bus.log("pip: frame failed") }
        if display.status == .failed { display.flush() }
        display.enqueue(buf)
    }

    /// 深色底 + 渐变声波图标 + 状态
    private static func image(_ text: String) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let cg = ctx.cgContext
            UIColor(red: 0.09, green: 0.1, blue: 0.18, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            let colors = [UIColor(red: 0.13, green: 0.76, blue: 1, alpha: 1), UIColor(red: 0.48, green: 0.36, blue: 1, alpha: 1), UIColor(red: 1, green: 0.24, blue: 0.55, alpha: 1)]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])!
            // 图标：与 Logo 相同的 5 根声波条
            let s: CGFloat = 150, ox: CGFloat = 50, oy = (size.height - s) / 2
            let w = s * 0.09, gap = s * 0.08
            let total = w * 5 + gap * 4
            let path = UIBezierPath()
            for (i, h) in ([6, 14, 20, 12, 4] as [CGFloat]).enumerated() {
                let bh = s * h / 32 + w
                let x = ox + (s - total) / 2 + CGFloat(i) * (w + gap)
                path.append(UIBezierPath(roundedRect: CGRect(x: x, y: oy + (s - bh) / 2, width: w, height: bh), cornerRadius: w / 2))
            }
            cg.saveGState()
            path.addClip()
            cg.drawLinearGradient(grad, start: CGPoint(x: ox, y: 0), end: CGPoint(x: ox + s, y: 0), options: [])
            cg.restoreGState()
            // 底部渐变细条
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: size.height - 6, width: size.width, height: 6))
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
            cg.restoreGState()
            let tx = ox + s + 30
            ("VoiceKey" as NSString).draw(at: CGPoint(x: tx, y: 82), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor(white: 1, alpha: 0.55)])
            (text as NSString).draw(at: CGPoint(x: tx, y: 124), withAttributes: [.font: UIFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: UIColor.white])
        }
    }

    private static func sample(_ img: UIImage) -> CMSampleBuffer? {
        guard let cg = img.cgImage else { return nil }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cg.width, height: cg.height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &out) == noErr, let out else { return nil }
        if let a = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return out
    }
}

extension PiPStandby: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        running = true
        pending = false
        deadline?.cancel()
        Bus.log("pip: active state=\(UIApplication.shared.applicationState.rawValue)")
        draw()
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let e = error as NSError
        Bus.log("pip: failed to start \(e.domain) \(e.code) \(e.localizedDescription)")
        running = false
        guard wanted else { return }
        if pending {
            // 启动阶段失败继续重试，超时才算打不开
            kick()
        } else if UIApplication.shared.applicationState == .background {
            onLost?("auto start failed \(e.domain) \(e.code)")
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        let st = UIApplication.shared.applicationState
        Bus.log("pip: stopped state=\(st.rawValue) restoring=\(restoring) wanted=\(wanted)")
        running = false
        let restored = restoring
        restoring = false
        guard wanted else { return }
        if restored {
            // 用户点小窗回到 App：小窗随会话常驻，回前台后重新打开
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.wanted, !self.running, UIApplication.shared.applicationState != .background else { return }
                self.start()
            }
        } else if st == .background {
            onLost?("stopped in background")
        }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        completionHandler(true)
    }
}

extension PiPStandby: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
