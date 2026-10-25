import AppKit
import Foundation
import OpenGL.GL
import OpenGL.GL3
import SwiftUI

/// Holds mpv callback targets. Must not be a MainActor type: mpv's core
/// thread invokes wakeup/update from outside the UI.
private final class MPVCallbackBox: @unchecked Sendable {
    weak var view: MPVGLView?
    nonisolated(unsafe) var mpv: OpaquePointer?
    let queue = DispatchQueue(label: "app.glossa.mpv", qos: .userInteractive)

    func drainEvents() {
        while let handle = mpv {
            let ev = mpv_wait_event(handle, 0)
            guard let ev, ev.pointee.event_id != MPV_EVENT_NONE else { break }
            if ev.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        DispatchQueue.main.async { [weak self] in
            self?.view?.onEvent?()
        }
    }
}

final class MPVGLView: NSOpenGLView {
    nonisolated(unsafe) private var mpv: OpaquePointer?
    nonisolated(unsafe) private var mpvGL: OpaquePointer?
    private var defaultFBO: GLint = -1
    private let box = MPVCallbackBox()
    var onEvent: (() -> Void)?

    static func create() -> MPVGLView {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAColorSize), 32,
            UInt32(NSOpenGLPFADepthSize), 24,
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            0,
        ]
        let format = NSOpenGLPixelFormat(attributes: attrs)!
        let view = MPVGLView(frame: .zero, pixelFormat: format)!
        view.wantsBestResolutionOpenGLSurface = true
        view.autoresizingMask = [.width, .height]
        view.box.view = view
        return view
    }

    func setup() {
        openGLContext?.makeCurrentContext()
        var swap: GLint = 1
        openGLContext?.setValues(&swap, for: .swapInterval)
        createMpv()
    }

    private func createMpv() {
        mpv = mpv_create()
        guard let mpv else { return }
        box.mpv = mpv
        mpv_request_log_messages(mpv, "warn")
        setOption("vo", "libmpv")
        setOption("hwdec", "videotoolbox")
        setOption("gpu-hwdec-interop", "auto")
        setOption("sub-visibility", "no")
        setOption("osd-level", "0")
        setOption("keep-open", "yes")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("ytdl", "no")
        mpv_initialize(mpv)

        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in MPVGLView.procAddress(name) },
            get_proc_address_ctx: nil
        )
        withUnsafeMutablePointer(to: &initParams) { initParams in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParams),
                mpv_render_param(),
            ]
            if mpv_render_context_create(&mpvGL, mpv, &params) < 0 {
                NSLog("Glossa: failed to create mpv render context")
            }
        }
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        if let mpvGL {
            mpv_render_context_set_update_callback(mpvGL, MPVGLView.onUpdate, boxPtr)
        }
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(mpv, MPVGLView.onWakeup, boxPtr)
    }

    private static let onWakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
        guard let ptr else { return }
        let box = Unmanaged<MPVCallbackBox>.fromOpaque(ptr).takeUnretainedValue()
        box.queue.async { box.drainEvents() }
    }

    private static let onUpdate: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
        guard let ptr else { return }
        let box = Unmanaged<MPVCallbackBox>.fromOpaque(ptr).takeUnretainedValue()
        DispatchQueue.main.async { box.view?.needsDisplay = true }
    }

    func loadFile(_ url: URL) {
        command("loadfile", args: [url.path, "replace"])
        setFlag("pause", false)
    }

    func command(_ cmd: String, args: [String] = []) {
        guard mpv != nil else { return }
        var cargs: [UnsafePointer<CChar>?] = ([cmd] + args).map { UnsafePointer(strdup($0)!) }
        cargs.append(nil)
        defer {
            for p in cargs {
                if let p { free(UnsafeMutablePointer(mutating: p)) }
            }
        }
        _ = mpv_command(mpv, &cargs)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard mpv != nil else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
    }

    func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var v: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var v = 0.0
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
        return v
    }

    func setString(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, name, value)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext, let mpvGL else {
            super.draw(dirtyRect)
            return
        }
        context.makeCurrentContext()
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &defaultFBO)
        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        var data = mpv_opengl_fbo(fbo: Int32(defaultFBO), w: dims[2], h: dims[3], internal_format: 0)
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &data) { data in
            withUnsafeMutablePointer(to: &flip) { flip in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: data),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flip),
                    mpv_render_param(),
                ]
                mpv_render_context_render(mpvGL, &params)
            }
        }
        context.flushBuffer()
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    deinit {
        box.view = nil
        box.mpv = nil
        if let mpvGL {
            mpv_render_context_set_update_callback(mpvGL, nil, nil)
            mpv_render_context_free(mpvGL)
        }
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
        }
    }

    private static func procAddress(_ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
        guard let name else { return nil }
        let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, UInt32(kCFStringEncodingASCII))
        let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
        return CFBundleGetFunctionPointerForName(bundle, symbol)
    }
}

struct MPVHost: NSViewRepresentable {
    var model: PlayerModel

    @MainActor
    func makeNSView(context: Context) -> MPVGLView {
        let view = MPVGLView.create()
        view.setup()
        view.onEvent = { model.tick() }
        model.attach(view)
        return view
    }

    func updateNSView(_ nsView: MPVGLView, context: Context) {}
}
