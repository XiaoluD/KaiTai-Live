// 内嵌播放内核（libmpv）
//
// 只在 VARIANT=embedded 时参与编译（-D EMBEDDED），精简版完全不含这段代码，包体积不受影响。
//
// 为什么用软件渲染而不是 OpenGL：
//   1. 播放视图要盖在 WKWebView 上，而 WKWebView 是 layer-backed 的，整条祖先链都会被
//      带上 layer。NSOpenGLView 在这种层级里画不出来（黑屏），这是老问题；
//      走 CAOpenGLLayer 能解决，但代价是一大堆 CGL 互操作。
//   2. MPV_RENDER_API_TYPE_SW 直接把画面渲到一块 RGBA 内存里，包成 CGImage 塞给
//      layer.contents 就行——不依赖任何已废弃的图形 API，也不会因为层级关系翻车。
//   3. 代价是每帧一次内存写入。按视口实际像素渲染、上限 1080p，单帧约 3–6 ms，
//      25–30 fps 直播完全够用。真要 4K 硬解时换成 Metal/GL 渲染器即可，接口不用动。
//
// 为什么每帧单独分配缓冲：CALayer 会按 CGImage 的对象身份缓存 GPU 纹理。
// 如果复用几块缓冲原地改写像素，CA 展示的可能还是几帧前的旧纹理——
// 实测表现是「画面冻在上一任频道的帧 + 偶尔闪烁」。每帧一个新 CGImage，
// CA 必然重传纹理；旧图像在 layer 换 contents 后销毁，releaseData 把内存还回去。

#if EMBEDDED

import AppKit
import ImageIO
// libmpv 的 C 接口由 mpv-bridge.h 桥接进来（见该文件注释），这里不需要 import 任何模块

final class MpvPlayerView: NSView {

    // MARK: 对外回调

    /// 出第一帧画面（此时才把视图显示出来，之前让网页的「正在连接…」盖着）
    var onFirstFrame: (() -> Void)?
    /// 失败：给出人话
    var onFailed: ((String) -> Void)?
    /// 正常播完 / 被停止
    var onEnded: (() -> Void)?

    // MARK: 内部状态

    private var mpv: OpaquePointer?
    private var rctx: OpaquePointer?

    private var bufW = 0
    private var bufH = 0
    private var bufStride = 0

    private var playing = false
    private var gotFirstFrame = false
    private var dumpedFrame = false
    private var loadTimeout: DispatchWorkItem?
    private let renderQueue = DispatchQueue(label: "kaitai.mpv.render")
    private var renderPending = false
    private static let swFormat = strdup("rgb0")!

    // MARK: 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.isOpaque = true
        // 和网页里 .screen 的圆角对齐，否则四角会露出直角
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setupMPV()
    }

    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 创建")
    }

    override var isOpaque: Bool { true }

    deinit {
        loadTimeout?.cancel()
    }

    // MARK: mpv 生命周期

    private func setupMPV() {
        guard let h = mpv_create() else {
            NSLog("[mpv] mpv_create 失败")
            return
        }
        mpv = h

        // vo=libmpv 是 render API 的前提；idle=yes 让 END_FILE 之后句柄还活着，
        // 可以继续 loadfile 下一个台，不用重建内核。
        mpv_set_option_string(h, "vo", "libmpv")
        mpv_set_option_string(h, "idle", "yes")
        mpv_set_option_string(h, "keep-open", "no")
        mpv_set_option_string(h, "terminal", "no")
        mpv_set_option_string(h, "hwdec", "videotoolbox")
        mpv_set_option_string(h, "audio-client-name", "开台 Full")
        mpv_set_option_string(h, "cache", "yes")
        mpv_set_option_string(h, "demuxer-max-bytes", "48MiB")
        mpv_set_option_string(h, "network-timeout", "15")
        // 咪咕 GSLB 会 302 到多个边缘节点，部分边缘是死的（404/无响应）——
        // 一次请求撞上就整场失败。开 ffmpeg 层自动重连，让播放器自己换边重试。
        mpv_set_option_string(
            h, "demuxer-lavf-o",
            "reconnect_streamed=1,reconnect_delay_max=3,http_multiple=1")
        // 不需要 youtube-dl 那套；不关的话每个地址都会先被 ytdl_hook 试一遍
        mpv_set_option_string(h, "ytdl", "no")
        // 不少 IPTV 源站会按 UA 挑人，装成常见播放器更稳
        mpv_set_option_string(
            h, "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")

        let rc = mpv_initialize(h)
        guard rc >= 0 else {
            NSLog("[mpv] mpv_initialize 失败: %@", String(cString: mpv_error_string(rc)))
            return
        }
        mpv_request_log_messages(h, "warn")
        setupRenderContext()
        startEventLoop()
    }

    private func setupRenderContext() {
        guard let mpv else { return }

        let apiType = strdup("sw")!
        defer { free(apiType) }

        var newCtx: OpaquePointer?
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                             data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
        ]
        let rc = mpv_render_context_create(&newCtx, mpv, &params)
        guard rc >= 0, let ctx = newCtx else {
            NSLog("[mpv] render_context_create 失败: %@", String(cString: mpv_error_string(rc)))
            return
        }
        rctx = ctx

        mpv_render_context_set_update_callback(
            ctx,
            { rawCtx in
                guard let rawCtx else { return }
                let view = Unmanaged<MpvPlayerView>.fromOpaque(rawCtx).takeUnretainedValue()
                view.requestRender()
            },
            Unmanaged.passUnretained(self).toOpaque())

        NSLog("[mpv] 渲染器就绪（software）")
    }

    private func startEventLoop() {
        guard mpv != nil else { return }
        // 故意强持有 self：这条线程是 mpv_wait_event(-1) 的阻塞循环，一旦 self 先被释放、
        // 而 mpv_terminate_destroy 又跑过了，下一个 event 就是野指针。视图本来就和
        // app 同生命周期，让它活着最省事，进程退出时由系统回收。
        Thread.detachNewThread { [self] in
            while let h = mpv {
                guard let evPtr = mpv_wait_event(h, -1) else { break }
                let ev = evPtr.pointee
                if ev.event_id == MPV_EVENT_NONE { continue }
                handle(ev)
            }
        }
    }

    private func handle(_ ev: mpv_event) {
        switch ev.event_id {
        case MPV_EVENT_END_FILE:
            guard let raw = ev.data else { return }
            let ef = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            // STOP / QUIT 是我们自己切台触发的，不算失败
            if ef.reason == MPV_END_FILE_REASON_ERROR {
                let msg = String(cString: mpv_error_string(ef.error))
                NSLog("[mpv] 播放失败: %@", msg)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loadTimeout?.cancel()
                    self.playing = false
                    self.onFailed?(msg)
                }
            } else if ef.reason == MPV_END_FILE_REASON_EOF {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loadTimeout?.cancel()
                    self.playing = false
                    self.onEnded?()
                }
            }

        case MPV_EVENT_LOG_MESSAGE:
            guard let raw = ev.data else { return }
            let lm = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            if let prefix = lm.prefix, let text = lm.text {
                let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    NSLog("[mpv/%@] %@", String(cString: prefix), line)
                }
            }

        case MPV_EVENT_SHUTDOWN:
            NSLog("[mpv] 内核退出")

        default:
            break
        }
    }

    // MARK: 播放控制

    func play(_ url: String) {
        NSLog("[mpv] play: %@", url)
        guard mpv != nil, rctx != nil else {
            onFailed?("播放内核没起来")
            return
        }
        playing = true
        gotFirstFrame = false
        dumpedFrame = false   // 自检用：每个台的第一帧都落一次盘
        mpv_set_property_string(mpv, "pause", "no")   // 换台自动解除暂停

        // 先把上一任频道的画面擦掉，别让「正在连接…」底下透出旧帧
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = nil
            CATransaction.commit()
        }

        runCommand(["loadfile", url, "replace"])

        loadTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 有些源连得上但一直没画面（限速、卡在第一帧），不能无限等
            guard self.playing, !self.gotFirstFrame else { return }
            self.playing = false
            self.runCommand(["stop"])
            self.onFailed?("12 秒内没有出画面——源站可能已下线、限速，或这条线路当前拥堵。")
        }
        loadTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func stop() {
        loadTimeout?.cancel()
        playing = false
        gotFirstFrame = false
        runCommand(["stop"])
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = nil
            CATransaction.commit()
        }
    }

    func setPaused(_ paused: Bool) {
        guard let h = mpv else { return }
        mpv_set_property_string(h, "pause", paused ? "yes" : "no")
    }

    /// 运行时改 mpv 属性（设置面板的硬解开关走这里）
    func setOption(_ key: String, _ value: String) {
        guard let h = mpv else { return }
        let rc = mpv_set_property_string(h, key, value)
        if rc < 0 {
            NSLog("[mpv] setopt %@=%@ 失败: %@", key, value, String(cString: mpv_error_string(rc)))
        }
    }

    func setVolume(_ v: Double) {
        guard let h = mpv else { return }
        var value = max(0, min(100, v))
        mpv_set_property(h, "volume", MPV_FORMAT_DOUBLE, &value)
    }

    private func runCommand(_ args: [String]) {
        guard let h = mpv else { return }
        let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { for p in owned { if let p { free(p) } } }
        var cargs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
        cargs.append(nil)
        let rc = mpv_command(h, &cargs)
        if rc < 0 {
            NSLog("[mpv] command %@ 失败: %@",
                  args.first ?? "-", String(cString: mpv_error_string(rc)))
        }
    }

    // MARK: 渲染

    private func requestRender() {
        guard rctx != nil, playing else { return }
        if renderPending { return }
        renderPending = true
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.renderPending = false
            self.renderFrame()
        }
    }

    /// 视口尺寸变化（窗口拉伸、网页布局变动）时重渲一帧
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestRender()
    }

    private func renderFrame() {
        guard let rctx, playing else { return }
        let scale = window?.backingScaleFactor ?? 2
        var w = Int(bounds.width * scale)
        var h = Int(bounds.height * scale)
        guard w > 8, h > 8 else { return }

        // 上限 1080p：再高的分辨率也不值得每帧多写一倍内存
        let maxW = 1920, maxH = 1080
        if w > maxW || h > maxH {
            let k = min(Double(maxW) / Double(w), Double(maxH) / Double(h))
            w = max(8, Int(Double(w) * k))
            h = max(8, Int(Double(h) * k))
        }

        // 每帧一块新内存：交给 makeImage 后由 releaseData 负责释放，这里不手动 free
        bufStride = ((w * 4) + 63) & ~63
        guard let mem = malloc(bufStride * h) else { return }

        // 这几个参数 mpv 要的是「指向值的指针」。用 allocate 显式管好生命周期，
        // 不能靠 &变量 的临时指针——那个在语句结束就失效了，mpv 渲染时会读到野指针。
        let sizePtr = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        sizePtr[0] = Int32(w)
        sizePtr[1] = Int32(h)
        let stridePtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        stridePtr.pointee = bufStride
        let blockPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        blockPtr.pointee = 0
        defer {
            sizePtr.deallocate()
            stridePtr.deallocate()
            blockPtr.deallocate()
        }

        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                             data: UnsafeMutableRawPointer(sizePtr)),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                             data: UnsafeMutableRawPointer(Self.swFormat)),
            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                             data: UnsafeMutableRawPointer(stridePtr)),
            // 注意：这个参数要的是缓冲区指针本身（void*），不是 void**。
            // 传成 &buf 会让 mpv 把「指针变量的栈地址」当画布，直接往栈上写。
            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                             data: mem),
            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
                             data: UnsafeMutableRawPointer(blockPtr)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
        ]

        let rc = mpv_render_context_render(rctx, &params)
        guard rc >= 0 else {
            free(mem)
            NSLog("[mpv] render 失败: %@", String(cString: mpv_error_string(rc)))
            return
        }

        guard let img = makeImage(w, h, mem) else { return } // makeImage 失败时 provider 销毁会释放 mem

        present(img)

        let hasContent = frameHasContent(mem, h)
        if hasContent { maybeDumpFrame(w, h, mem: mem) }

        if !gotFirstFrame && hasContent {
            gotFirstFrame = true
            NSLog("[mpv] 首帧完成 %dx%d", w, h)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadTimeout?.cancel()
                self.onFirstFrame?()
            }
        }
    }

    /// 每帧新建 CGImage。旧图像会在 layer 换 contents 后销毁，
    /// releaseData 此时才把像素内存还回去——保证「显示中」的缓冲绝不会被复用。
    private func makeImage(_ w: Int, _ h: Int, _ mem: UnsafeMutableRawPointer) -> CGImage? {
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(dataInfo: nil, data: mem,
                                            size: bufStride * h,
                                            // 回调给的是 UnsafeRawPointer，这里明确知道
                                            // 是自己 malloc 的内存，转回可变指针去 free
                                            releaseData: { _, data, _ in
                                                free(UnsafeMutableRawPointer(mutating: data))
                                            })
        else { return nil }
        // mpv 的 "rgb0" 在内存里是 R,G,B,X，对应 32 位大端 + 跳过最后一个分量
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bufStride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 采样判断这一帧是不是纯黑。死源失败前 mpv 也会送一帧过来，
    /// 不能拿它当「出画面」，否则网页的「正在连接…」会提前消失。
    private func frameHasContent(_ mem: UnsafeMutableRawPointer, _ h: Int) -> Bool {
        let bytes = mem.assumingMemoryBound(to: UInt8.self)
        var hits = 0
        var i = 0
        while i < bufStride * h {
            if bytes[i] > 12 || bytes[i + 1] > 12 || bytes[i + 2] > 12 {
                hits += 1
                if hits > 8 { return true }
            }
            i += 4000
        }
        return false
    }

    private func present(_ img: CGImage) {
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = img
            CATransaction.commit()
        }
    }

    /// 自检用：把 mpv 真正渲染出来的像素落成 PNG，用来确认「不是黑屏、不是花屏」
    private func maybeDumpFrame(_ w: Int, _ h: Int, mem: UnsafeMutableRawPointer) {
        guard !dumpedFrame,
              let path = ProcessInfo.processInfo.environment["IPTV_DUMP_FRAME"],
              !path.isEmpty
        else { return }

        dumpedFrame = true
        guard let provider = CGDataProvider(dataInfo: nil, data: mem, size: bufStride * h,
                                            releaseData: { _, _, _ in }),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: bufStride, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(
                                    rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true,
                                intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        NSLog("[mpv] 已把首帧存到 %@ （%dx%d）", path, w, h)
    }
}

#endif
