import Foundation
import GhosttyKit
import QuartzCore
import UIKit
import Darwin

enum GhosttyKitRuntimeError: Error, Equatable {
    case initializationFailed(Int32)
    case processDirectoryConfigurationFailed(String)
    case environmentConfigurationFailed(String)
    case runtimeConfigurationFileFailed(String)
    case configCreationFailed
    case appCreationFailed
    case surfaceCreationFailed
}

struct GhosttyTerminalAppearance: Equatable {
    let fontSize: Float32?

    func apply(to config: inout ghostty_surface_config_s) {
        guard let fontSize, config.font_size == 0 else { return }
        config.font_size = fontSize
    }
}

enum GhosttyTerminalDeviceClass {
    case phone
    case pad
}

enum GhosttyTerminalAppearancePolicy {
    static let phoneMinimumFontSize: Float32 = 11
    static let phoneDefaultFontSize: Float32 = 11

    static func appearance(
        for settings: TerminalSettings,
        deviceClass: GhosttyTerminalDeviceClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> GhosttyTerminalAppearance {
        if let fontSize = settings.fontSize {
            return GhosttyTerminalAppearance(fontSize: fontSize)
        }

        return appearance(
            for: deviceClass,
            contentSizeCategory: contentSizeCategory
        )
    }

    static func appearance(
        for deviceClass: GhosttyTerminalDeviceClass,
        contentSizeCategory: UIContentSizeCategory = .large
    ) -> GhosttyTerminalAppearance {
        switch deviceClass {
        case .phone:
            GhosttyTerminalAppearance(
                fontSize: phoneFontSize(contentSizeCategory: contentSizeCategory)
            )
        case .pad:
            GhosttyTerminalAppearance(fontSize: nil)
        }
    }

    @MainActor
    static func currentDeviceAppearance(settings: TerminalSettings = .default) -> GhosttyTerminalAppearance {
        let contentSizeCategory = UIApplication.shared.preferredContentSizeCategory

        return switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            appearance(
                for: settings,
                deviceClass: .phone,
                contentSizeCategory: contentSizeCategory
            )
        case .pad:
            appearance(
                for: settings,
                deviceClass: .pad,
                contentSizeCategory: contentSizeCategory
            )
        default:
            GhosttyTerminalAppearance(fontSize: settings.fontSize)
        }
    }

    private static func phoneFontSize(contentSizeCategory: UIContentSizeCategory) -> Float32 {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: CGFloat(phoneDefaultFontSize),
            compatibleWith: traits
        )

        return Float32(max(scaledSize, CGFloat(phoneMinimumFontSize)))
    }
}

final class GhosttyKitSurfaceView: UIView {
    override init(frame: CGRect) {
        let initialFrame = frame.isEmpty
            ? CGRect(x: 0, y: 0, width: 1, height: 1)
            : frame
        super.init(frame: initialFrame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignGhosttyRendererSublayers()
    }

    func alignGhosttyRendererSublayers() {
        let scale = max(window?.screen.scale ?? contentScaleFactor, 1)
        layer.contentsScale = scale

        guard let sublayers = layer.sublayers else { return }
        for sublayer in sublayers {
            sublayer.frame = bounds
            sublayer.contentsScale = scale
            sublayer.setNeedsDisplay()
        }
    }

    private func configure() {
        backgroundColor = .black
        clipsToBounds = true
        isOpaque = true
        contentScaleFactor = max(UIScreen.main.scale, 1)
    }
}

@MainActor
final class GhosttyKitRuntime {
    typealias ManualWriteHandler = @Sendable (_ data: Data, _ linefeed: Bool) -> Bool
    typealias ManualResizeHandler = @Sendable (
        _ columns: UInt16,
        _ rows: UInt16,
        _ width: UInt32,
        _ height: UInt32
    ) -> Bool
    typealias ManualFocusHandler = @Sendable (_ focused: Bool) -> Bool

    private static var initialized = false

    private let state: GhosttyKitRuntimeState

    init(
        surfaceDelegate: GhosttyKitRuntimeSurfaceDelegate? = nil,
        terminalSettings: TerminalSettings = .default
    ) throws {
        try Self.initializeBackend()
        state = try GhosttyKitRuntimeState(
            surfaceDelegate: surfaceDelegate,
            terminalSettings: terminalSettings
        )
    }

#if DEBUG
    var appHandleForTesting: ghostty_app_t {
        state.app
    }
#endif

    func makeManualHostSurface(
        view: UIView,
        initialSize: CGSize? = nil,
        onWrite: ManualWriteHandler? = nil,
        onResize: ManualResizeHandler? = nil,
        onFocus: ManualFocusHandler? = nil
    ) throws -> GhosttyKitControlSurface {
        let callbacks = GhosttyKitManualSurfaceCallbacks(
            onWrite: onWrite,
            onResize: onResize,
            onFocus: onFocus
        )

        var surfaceConfig = ghostty_surface_config_new()
        GhosttyTerminalAppearancePolicy
            .currentDeviceAppearance(settings: state.terminalSettings)
            .apply(to: &surfaceConfig)
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(view).toOpaque()
        ))
        surfaceConfig.scale_factor = max(Double(view.contentScaleFactor), 1)
        let metrics = GhosttySurfaceDisplayMetrics(
            size: initialSize ?? view.bounds.size,
            scale: view.contentScaleFactor
        )
        surfaceConfig.initial_width_px = metrics.pixelWidth
        surfaceConfig.initial_height_px = metrics.pixelHeight
        surfaceConfig.initial_focused = false
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        surfaceConfig.manual_userdata = callbacks.userdata
        surfaceConfig.manual_write = callbacks.writeCallback
        surfaceConfig.manual_resize = callbacks.resizeCallback
        surfaceConfig.manual_focus = callbacks.focusCallback

        guard let surface = ghostty_surface_new(state.app, &surfaceConfig) else {
            throw GhosttyKitRuntimeError.surfaceCreationFailed
        }

        return GhosttyKitControlSurface(
            surface: surface,
            ownership: .storageOwned,
            retainedObjects: [state, callbacks]
        )
    }

    private static func initializeBackend() throws {
        guard !initialized else { return }

        try configureProcessDirectories()

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyKitRuntimeError.initializationFailed(result)
        }

        initialized = true
    }

    private static func configureProcessDirectories() throws {
        let home = NSHomeDirectory()
        let applicationSupport = "\(home)/Library/Application Support"
        let caches = "\(home)/Library/Caches"

        try createDirectoryIfNeeded(at: applicationSupport)
        try createDirectoryIfNeeded(at: caches)

        try setEnvironment("HOME", to: home)
        try setEnvironment("XDG_CONFIG_HOME", to: applicationSupport)
        try setEnvironment("XDG_CACHE_HOME", to: caches)
        try setEnvironment("XDG_STATE_HOME", to: applicationSupport)
    }

    private static func createDirectoryIfNeeded(at path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
        } catch {
            throw GhosttyKitRuntimeError.processDirectoryConfigurationFailed(path)
        }
    }

    private static func setEnvironment(_ name: String, to value: String) throws {
        guard getenv(name) == nil else { return }

        let result = name.withCString { namePointer in
            value.withCString { valuePointer in
                setenv(namePointer, valuePointer, 1)
            }
        }

        guard result == 0 else {
            throw GhosttyKitRuntimeError.environmentConfigurationFailed(name)
        }
    }
}

private final class GhosttyKitRuntimeState {
    let app: ghostty_app_t
    let terminalSettings: TerminalSettings

    private let config: ghostty_config_t
    private let callbacks: GhosttyKitRuntimeCallbacks

    @MainActor
    init(
        surfaceDelegate: GhosttyKitRuntimeSurfaceDelegate?,
        terminalSettings: TerminalSettings
    ) throws {
        guard let config = ghostty_config_new() else {
            throw GhosttyKitRuntimeError.configCreationFailed
        }
        try Self.loadSettings(terminalSettings, into: config)
        ghostty_config_finalize(config)

        let callbacks = GhosttyKitRuntimeCallbacks()
        callbacks.surfaceDelegate = surfaceDelegate
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: callbacks.userdata,
            supports_selection_clipboard: false,
            wakeup_cb: GhosttyKitRuntimeCallbacks.wakeupCallback,
            action_cb: GhosttyKitRuntimeCallbacks.actionCallback,
            read_clipboard_cb: GhosttyKitRuntimeCallbacks.readClipboardCallback,
            confirm_read_clipboard_cb: GhosttyKitRuntimeCallbacks.confirmReadClipboardCallback,
            write_clipboard_cb: GhosttyKitRuntimeCallbacks.writeClipboardCallback,
            close_surface_cb: GhosttyKitRuntimeCallbacks.closeSurfaceCallback,
            select_surface_cb: GhosttyKitRuntimeCallbacks.selectSurfaceCallback,
            create_surface_cb: GhosttyKitRuntimeCallbacks.createSurfaceCallback,
            create_surface_tree_cb: GhosttyKitRuntimeCallbacks.createSurfaceTreeCallback,
            tmux_command_failure_cb: GhosttyKitRuntimeCallbacks.tmuxCommandFailureCallback
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw GhosttyKitRuntimeError.appCreationFailed
        }

        self.app = app
        self.config = config
        self.callbacks = callbacks
        self.terminalSettings = terminalSettings
        callbacks.app = app
    }

    deinit {
        // A wakeup callback may have queued a MainActor tick. Clear the pointer
        // before freeing so the queued task cannot tick a destroyed app.
        callbacks.app = nil
        ghostty_app_free(app)
        ghostty_config_free(config)
        _ = callbacks
    }

    private static func loadSettings(
        _ settings: TerminalSettings,
        into config: ghostty_config_t
    ) throws {
        guard let contents = settings.ghosttyConfigContents else { return }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remux-ghostty-\(UUID().uuidString).conf")

        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw GhosttyKitRuntimeError.runtimeConfigurationFileFailed(fileURL.path)
        }
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        fileURL.path.withCString { path in
            ghostty_config_load_file(config, path)
        }
    }
}

private final class GhosttyKitRuntimeCallbacks: @unchecked Sendable {
    var app: ghostty_app_t?
    weak var surfaceDelegate: GhosttyKitRuntimeSurfaceDelegate?

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static var wakeupCallback: ghostty_runtime_wakeup_cb {
        { userdata in
            GhosttyKitRuntimeCallbacks.wakeup(userdata)
        }
    }

    static var actionCallback: ghostty_runtime_action_cb {
        { app, target, action in
            GhosttyKitRuntimeCallbacks.action(app, target: target, action: action)
        }
    }

    static var readClipboardCallback: ghostty_runtime_read_clipboard_cb {
        { userdata, clipboard, request in
            GhosttyKitRuntimeCallbacks.readClipboard(userdata, clipboard: clipboard, request: request)
        }
    }

    static var confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb {
        { userdata, string, request, kind in
            GhosttyKitRuntimeCallbacks.confirmReadClipboard(
                userdata,
                string: string,
                request: request,
                kind: kind
            )
        }
    }

    static var writeClipboardCallback: ghostty_runtime_write_clipboard_cb {
        { userdata, clipboard, contents, count, confirm in
            GhosttyKitRuntimeCallbacks.writeClipboard(
                userdata,
                clipboard: clipboard,
                contents: contents,
                count: count,
                confirm: confirm
            )
        }
    }

    static var closeSurfaceCallback: ghostty_runtime_close_surface_cb {
        { userdata, processAlive in
            GhosttyKitRuntimeCallbacks.closeSurface(userdata, processAlive: processAlive)
        }
    }

    static var selectSurfaceCallback: ghostty_runtime_select_surface_cb {
        { app, surface in
            GhosttyKitRuntimeCallbacks.selectSurface(app, surface: surface)
        }
    }

    static var createSurfaceCallback: ghostty_runtime_create_surface_cb {
        { app, request in
            GhosttyKitRuntimeCallbacks.createSurface(app, request: request)
        }
    }

    static var createSurfaceTreeCallback: ghostty_runtime_create_surface_tree_cb {
        { app, request in
            GhosttyKitRuntimeCallbacks.createSurfaceTree(app, request: request)
        }
    }

    static var tmuxCommandFailureCallback: ghostty_runtime_tmux_command_failure_cb {
        { app, failure in
            GhosttyKitRuntimeCallbacks.tmuxCommandFailure(app, failure: failure)
        }
    }

    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let callbacks = from(userdata: userdata) else { return }
        Task { @MainActor in
            guard let app = callbacks.app else { return }
            ghostty_app_tick(app)
        }
    }

    static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let callbacks = from(app: app) else { return true }
        let appBox = UnsafeSendable(app)
        let targetBox = UnsafeSendable(target)
        let actionBox = UnsafeSendable(action)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.action route=main")
            return MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeAction(
                    app: appBox.value,
                    target: targetBox.value,
                    action: actionBox.value
                ) ?? true
            }
        } else {
            return GhosttyRuntimeTrace.perfMeasure("runtime.action route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeAction(
                            app: appBox.value,
                            target: targetBox.value,
                            action: actionBox.value
                        ) ?? true
                    }
                }
            }
        }
    }

    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        request: UnsafeMutableRawPointer?
    ) -> Bool {
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return false }
        guard let request else { return false }
        guard
            let lifecycle = GhosttyRuntimeSurfaceLifecycle.from(userdata),
            let surface = lifecycle.surfaceHandle
        else {
            return false
        }
        guard let text = readPasteboardString() else { return false }

        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                request,
                false
            )
        }
        return true
    }

    static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        request: UnsafeMutableRawPointer?,
        kind: ghostty_clipboard_request_e
    ) {
        guard let request else { return }
        guard
            let lifecycle = GhosttyRuntimeSurfaceLifecycle.from(userdata),
            let surface = lifecycle.surfaceHandle
        else {
            return
        }

        let text: String
        switch kind {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE, GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            text = string.map(String.init(cString:)) ?? ""
        default:
            // Do not expose the iOS pasteboard to terminal-initiated OSC 52
            // reads until Remux has a user-facing confirmation path.
            text = ""
        }

        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(
                surface,
                pointer,
                request,
                true
            )
        }
    }

    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        _ = userdata
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
        guard !confirm else { return }
        guard let text = GhosttyClipboardContentDecoder.plainText(
            contents: contents,
            count: count
        ) else {
            return
        }

        DispatchQueue.main.async {
            UIPasteboard.general.string = text
        }
    }

    private static func readPasteboardString() -> String? {
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.readPasteboard route=main")
            return UIPasteboard.general.string
        }

        return GhosttyRuntimeTrace.perfMeasure("runtime.readPasteboard route=sync") {
            DispatchQueue.main.sync {
                UIPasteboard.general.string
            }
        }
    }

    static func closeSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let lifecycle = GhosttyRuntimeSurfaceLifecycle.from(userdata) else {
            return
        }

        Task { @MainActor [weak registry = lifecycle.registry] in
            registry?.runtimeCloseSurface(
                id: lifecycle.surfaceID,
                processAlive: processAlive
            )
        }
    }

    static func createSurface(
        _ app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_s
    ) -> ghostty_surface_t? {
        guard let callbacks = from(app: app) else { return nil }
        let appBox = UnsafeSendable(app)
        let requestBox = UnsafeSendable(request)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.createSurface route=main")
            return MainActor.assumeIsolated {
                UnsafeSendable(callbacks.surfaceDelegate?.runtimeCreateSurface(
                    app: appBox.value,
                    request: requestBox.value
                ))
            }.value
        } else {
            return GhosttyRuntimeTrace.perfMeasure("runtime.createSurface route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        UnsafeSendable(callbacks.surfaceDelegate?.runtimeCreateSurface(
                            app: appBox.value,
                            request: requestBox.value
                        ))
                    }
                }
            }.value
        }
    }

    static func createSurfaceTree(
        _ app: ghostty_app_t?,
        request: ghostty_runtime_create_surface_tree_s
    ) -> Bool {
        guard let callbacks = from(app: app) else { return false }
        let appBox = UnsafeSendable(app)
        let requestBox = UnsafeSendable(request)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.createSurfaceTree route=main")
            return MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeCreateSurfaceTree(
                    app: appBox.value,
                    request: requestBox.value
                ) ?? false
            }
        } else {
            return GhosttyRuntimeTrace.perfMeasure("runtime.createSurfaceTree route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeCreateSurfaceTree(
                            app: appBox.value,
                            request: requestBox.value
                        ) ?? false
                    }
                }
            }
        }
    }

    static func selectSurface(
        _ app: ghostty_app_t?,
        surface: ghostty_surface_t?
    ) {
        guard let callbacks = from(app: app) else { return }
        let appBox = UnsafeSendable(app)
        let surfaceBox = UnsafeSendable(surface)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.selectSurface route=main")
            MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeSelectSurface(
                    app: appBox.value,
                    surface: surfaceBox.value
                )
            }
        } else {
            GhosttyRuntimeTrace.perfMeasure("runtime.selectSurface route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeSelectSurface(
                            app: appBox.value,
                            surface: surfaceBox.value
                        )
                    }
                }
            }
        }
    }

    static func tmuxCommandFailure(
        _ app: ghostty_app_t?,
        failure: ghostty_tmux_command_failure_s
    ) {
        guard let callbacks = from(app: app) else { return }
        let appBox = UnsafeSendable(app)
        let failureBox = UnsafeSendable(failure)
        if Thread.isMainThread {
            GhosttyRuntimeTrace.perf("runtime.tmuxCommandFailure route=main")
            MainActor.assumeIsolated {
                callbacks.surfaceDelegate?.runtimeTmuxCommandFailure(
                    app: appBox.value,
                    failure: failureBox.value
                )
            }
        } else {
            GhosttyRuntimeTrace.perfMeasure("runtime.tmuxCommandFailure route=sync") {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        callbacks.surfaceDelegate?.runtimeTmuxCommandFailure(
                            app: appBox.value,
                            failure: failureBox.value
                        )
                    }
                }
            }
        }
    }

    private static func from(app: ghostty_app_t?) -> GhosttyKitRuntimeCallbacks? {
        guard let app else { return nil }
        guard let userdata = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyKitRuntimeCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func from(userdata: UnsafeMutableRawPointer?) -> GhosttyKitRuntimeCallbacks? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyKitRuntimeCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }
}

private struct UnsafeSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class GhosttyKitManualSurfaceCallbacks: @unchecked Sendable {
    private let onWrite: GhosttyKitRuntime.ManualWriteHandler?
    private let onResize: GhosttyKitRuntime.ManualResizeHandler?
    private let onFocus: GhosttyKitRuntime.ManualFocusHandler?

    init(
        onWrite: GhosttyKitRuntime.ManualWriteHandler?,
        onResize: GhosttyKitRuntime.ManualResizeHandler?,
        onFocus: GhosttyKitRuntime.ManualFocusHandler?
    ) {
        self.onWrite = onWrite
        self.onResize = onResize
        self.onFocus = onFocus
    }

    var userdata: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    var writeCallback: ghostty_surface_manual_write_cb? {
        guard onWrite != nil else { return nil }
        return { userdata, data, count, linefeed in
            GhosttyKitManualSurfaceCallbacks.writeThunk(userdata, data, count, linefeed)
        }
    }

    var resizeCallback: ghostty_surface_manual_resize_cb? {
        guard onResize != nil else { return nil }
        return { userdata, columns, rows, width, height in
            GhosttyKitManualSurfaceCallbacks.resizeThunk(userdata, columns, rows, width, height)
        }
    }

    var focusCallback: ghostty_surface_manual_focus_cb? {
        guard onFocus != nil else { return nil }
        return { userdata, focused in
            GhosttyKitManualSurfaceCallbacks.focusThunk(userdata, focused)
        }
    }

    private static func writeThunk(
        _ userdata: UnsafeMutableRawPointer?,
        _ data: UnsafePointer<CChar>?,
        _ count: Int,
        _ linefeed: Bool
    ) -> Bool {
        write(userdata, data: data, count: count, linefeed: linefeed)
    }

    private static func resizeThunk(
        _ userdata: UnsafeMutableRawPointer?,
        _ columns: UInt16,
        _ rows: UInt16,
        _ width: UInt32,
        _ height: UInt32
    ) -> Bool {
        resize(userdata, columns: columns, rows: rows, width: width, height: height)
    }

    private static func focusThunk(
        _ userdata: UnsafeMutableRawPointer?,
        _ focused: Bool
    ) -> Bool {
        focus(userdata, focused: focused)
    }

    private static func write(
        _ userdata: UnsafeMutableRawPointer?,
        data: UnsafePointer<CChar>?,
        count: Int,
        linefeed: Bool
    ) -> Bool {
        guard let callbacks = from(userdata: userdata) else { return false }
        guard let onWrite = callbacks.onWrite else { return true }
        guard count >= 0 else { return false }

        if count == 0 {
            return onWrite(Data(), linefeed)
        }

        guard let data else { return false }
        return onWrite(Data(bytes: data, count: count), linefeed)
    }

    private static func resize(
        _ userdata: UnsafeMutableRawPointer?,
        columns: UInt16,
        rows: UInt16,
        width: UInt32,
        height: UInt32
    ) -> Bool {
        guard let callbacks = from(userdata: userdata) else { return false }
        guard let onResize = callbacks.onResize else { return true }
        return onResize(columns, rows, width, height)
    }

    private static func focus(
        _ userdata: UnsafeMutableRawPointer?,
        focused: Bool
    ) -> Bool {
        guard let callbacks = from(userdata: userdata) else { return false }
        guard let onFocus = callbacks.onFocus else { return true }
        return onFocus(focused)
    }

    private static func from(userdata: UnsafeMutableRawPointer?) -> GhosttyKitManualSurfaceCallbacks? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyKitManualSurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }
}
