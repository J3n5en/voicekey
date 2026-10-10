import AVKit
import UIKit

/// 画中画待机：系统挂 PIPVisible，后台可按需开麦。内容透明不代表系统 overlay 隐藏。
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
    private var retry: DispatchWorkItem?
    private let display = AVSampleBufferDisplayLayer()
    private let host = UIView(frame: CGRect(x: 0, y: 0, width: 369, height: 369.0 / 4680))
    private var controller: AVPictureInPictureController?
    private var possible: KVOToken?
    private var rendering: KVOToken?
    private var deadline: DispatchWorkItem?
    private var sessionGeneration = 0
    private var controllerGeneration = 0
    private var startSource = "none"
    private let trace: PiPTrace? = ProcessInfo.processInfo.arguments.contains("-piptrace")
        ? PiPTrace(url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/pip-state.txt")) : nil

    func diagnose(_ event: String, controller c: AVPictureInPictureController? = nil, throttle: Bool = false) {
        guard trace != nil else { return }
        if !Thread.isMainThread {
            let at = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                self?.diagnose("\(event) callbackUp=\(at) deferredSnapshot=true", controller: c, throttle: throttle)
            }
            return
        }
        trace?.record("event=\(event) session=\(sessionGeneration) controller=\(controllerGeneration) current=\(c == nil || c === controller) source=\(startSource) app=\(UIApplication.shared.applicationState.rawValue) wanted=\(wanted) pending=\(pending) running=\(running) restoring=\(restoring) active=\(controller?.isPictureInPictureActive ?? false) possible=\(controller?.isPictureInPicturePossible ?? false) auto=\(controller?.canStartPictureInPictureAutomaticallyFromInline ?? false) status=\(display.status.rawValue) host=\(host.bounds) display=\(display.bounds)", throttle: throttle)
    }

    func beginSessionTrace(mode: Standby) {
        sessionGeneration += 1
        diagnose("session.arm mode=\(mode.rawValue)")
    }

    override init() {
        super.init()
        display.frame = host.bounds
        display.videoGravity = .resizeAspect
        host.layer.addSublayer(display)
        host.isUserInteractionEnabled = false
        diagnose("init build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") os=\(UIDevice.current.systemVersion) supported=\(Self.supported)")
        if trace != nil {
            for name in [UIApplication.willResignActiveNotification, UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.diagnose("app.\(name.rawValue)")
                }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.diagnose("app.didEnterBackground")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, self.wanted, !self.running, UIApplication.shared.applicationState == .background else { return }
                self.onLost?("not running in background")
            }
        }
    }

    /// 打开小窗（须在前台）；窗口还没建好时等下次回到前台再开
    func start(source: String) {
        diagnose("start.request from=\(source)")
        wanted = true
        guard !running, attach() else {
            if !running { Bus.log("pip: no window yet") }
            return
        }
        guard !pending else { return }
        startSource = source
        if controller == nil {
            controllerGeneration += 1
            let c = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: display, playbackDelegate: self))
            c.delegate = self
            c.canStartPictureInPictureAutomaticallyFromInline = false
            c.requiresLinearPlayback = true
            controller = c
            possible = KVOToken(c, "pictureInPicturePossible") { [weak self] in
                DispatchQueue.main.async { self?.kick() }
            }
            rendering = KVOToken(display, "status") { [weak self] in
                DispatchQueue.main.async { self?.kick() }
            }
        }
        draw()
        pending = true
        deadline?.cancel()
        let d = DispatchWorkItem { [weak self] in
            guard let self, self.pending else { return }
            let reason = "start timeout possible=\(self.controller?.isPictureInPicturePossible ?? false) status=\(self.display.status.rawValue)"
            self.diagnose("start.timeout")
            self.stop()
            self.onFailed?(reason)
        }
        deadline = d
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: d)
        kick()
    }

    func stop() {
        diagnose("stop.request")
        wanted = false
        pending = false
        deadline?.cancel()
        deadline = nil
        retry?.cancel()
        retry = nil
        possible = nil
        rendering = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
        controller = nil
        running = false
        restoring = false
        display.flushAndRemoveImage()
        host.removeFromSuperview()
    }

    private func kick() {
        guard pending, let c = controller, !c.isPictureInPictureActive else { return }
        let ready = display.status == .rendering
        c.canStartPictureInPictureAutomaticallyFromInline = ready
        // KVO 不重复发起启动；仍保留定时重试，rendering 后也可能静默失败而没有 delegate 回调
        guard retry == nil else { return }
        let r = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            guard self.pending, !self.running else { return }
            self.kick()
        }
        retry = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: r)
        // 从键盘跳过来时 App 还在 inactive，这时开会报 -1001，等 active 再开
        if ready, c.isPictureInPicturePossible, UIApplication.shared.applicationState == .active {
            diagnose("start.api")
            Bus.log("pip: start status=\(display.status.rawValue) size=\(display.bounds.size)")
            c.startPictureInPicture()
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

    /// 启动时送全透明的极扁画面；系统控件的布局与可见性须另行观察。
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

/// 字符串 KVO：Swift keyPath 版 observe 在 iOS 27 上观察 AVPictureInPictureController 会在类型转换处崩（切画中画待机即闪退）
private final class KVOToken: NSObject {
    private let object: NSObject
    private let key: String
    private let onChange: () -> Void

    init(_ object: NSObject, _ key: String, _ onChange: @escaping () -> Void) {
        self.object = object
        self.key = key
        self.onChange = onChange
        super.init()
        object.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onChange()
    }

    deinit { object.removeObserver(self, forKeyPath: key) }
}

extension PiPStandby: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        diagnose("willStart", controller: c)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ c: AVPictureInPictureController) {
        diagnose("willStop", controller: c)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        diagnose("didStart", controller: c)
        guard c === controller, wanted else {
            c.stopPictureInPicture()
            return
        }
        running = true
        pending = false
        deadline?.cancel()
        retry?.cancel()
        retry = nil
        Bus.log("pip: active state=\(UIApplication.shared.applicationState.rawValue)")
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        diagnose("failed code=\((error as NSError).code)", controller: c)
        guard c === controller else { return }
        let e = error as NSError
        Bus.log("pip: failed to start \(e.domain) \(e.code) \(e.localizedDescription)")
        running = false
        guard wanted else { return }
        // pending 时由 retry 重试，避免失败回调同步重入 start
        if !pending, UIApplication.shared.applicationState == .background {
            onLost?("auto start failed \(e.domain) \(e.code)")
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        diagnose("didStop", controller: c)
        guard c === controller else { return }
        let st = UIApplication.shared.applicationState
        Bus.log("pip: stopped state=\(st.rawValue) restoring=\(restoring) wanted=\(wanted)")
        running = false
        let restored = restoring
        restoring = false
        guard wanted else { return }
        if restored {
            let scheduledSession = sessionGeneration
            let scheduledController = controllerGeneration
            diagnose("restore.schedule")
            // 用户点小窗回到 App：小窗随会话常驻，回前台后重新打开
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.diagnose("restore.fire scheduledSession=\(scheduledSession) scheduledController=\(scheduledController)")
                guard let self, self.wanted, !self.running, UIApplication.shared.applicationState != .background else { return }
                self.start(source: "restore.0.6s")
            }
        } else if st == .background {
            onLost?("stopped in background")
        }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        diagnose("restore", controller: c)
        guard c === controller, wanted else { return completionHandler(false) }
        restoring = true
        completionHandler(true)
    }
}

extension PiPStandby: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        diagnose("setPlaying=\(playing)", controller: c, throttle: true)
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        diagnose("renderSize=\(newRenderSize.width)x\(newRenderSize.height)", controller: c, throttle: true)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        diagnose("skip=\(skipInterval.seconds)", controller: c)
        completionHandler()
    }
}
