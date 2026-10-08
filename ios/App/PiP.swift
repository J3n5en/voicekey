import AVKit
import UIKit

/// 画中画待机：画中画开着时系统给 App 挂 PIPVisible，后台可按需开麦。小窗内容全透明且高度约为 0，用户看不到
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
    private let display = AVSampleBufferDisplayLayer()
    private let host = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 18))
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    private var deadline: DispatchWorkItem?

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

    /// 启动时送全透明的极扁画面：窗口高度约为 0，看不到窗口和把手（iPhone 13 / iOS 17.3.1 实测）
    private func draw() {
        guard let buf = Self.frame else { return Bus.log("pip: frame failed") }
        if display.status == .failed { display.flush() }
        display.enqueue(buf)
    }

    private static var frame: CMSampleBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 4680, 1, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
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
