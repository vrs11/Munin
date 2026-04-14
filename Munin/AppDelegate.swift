import AppKit
import ApplicationServices
import Carbon
import SwiftUI

@main
struct MuninApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep the app alive without creating a normal app window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let shortcutPreferences = ShortcutPreferences()
    private let quickPasteViewModel = QuickPasteViewModel()

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var panel: NSPanel?
    private var quickPastePanel: QuickPastePanel?
    private var configWindow: NSWindow?
    private var hotKeyManager: GlobalHotKeyManager?
    private var copyCommandMonitor: CopyCommandMonitor?
    private var isOpeningPanel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusItem()
        configureStatusMenu()
        configurePanel()
        configureQuickPastePanel()
        configureConfigWindow()
        configureHotKeyManager()
        configureCopyCommandMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopMonitoring()
        hotKeyManager?.unregister()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let icon = NSImage(
                systemSymbolName: "clipboard",
                accessibilityDescription: "Munin Clipboard History"
            )?.withSymbolConfiguration(symbolConfig)

            if let icon {
                icon.isTemplate = true
                button.image = icon
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.title = "M"
                button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            }

            button.toolTip = "Munin Clipboard History"
            button.action = #selector(togglePanel(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItem = item
    }

    private func configureStatusMenu() {
        let menu = NSMenu()

        let configItem = NSMenuItem(title: "Config", action: #selector(openConfigWindow(_:)), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        statusMenu = menu
    }

    private func configurePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentViewController = NSHostingController(
            rootView: ClipboardListView(store: store)
                .ignoresSafeArea(.container, edges: .top)
        )

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.panel = panel
    }

    private func configureQuickPastePanel() {
        let panel = QuickPastePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentViewController = NSHostingController(
            rootView: QuickPastePopupView(viewModel: quickPasteViewModel) { [weak self] entry in
                self?.insertEntryIntoFocusedApp(entry)
            }
            .ignoresSafeArea(.container, edges: .top)
        )

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.onEscape = { [weak self] in
            self?.hideQuickPastePanel()
        }
        panel.onArrowUp = { [weak self] in
            self?.quickPasteViewModel.moveSelection(delta: -1)
        }
        panel.onArrowDown = { [weak self] in
            self?.quickPasteViewModel.moveSelection(delta: 1)
        }
        panel.onEnter = { [weak self] in
            self?.activateSelectedQuickPasteEntry()
        }

        quickPastePanel = panel
    }

    private func configureConfigWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Munin Config"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: ShortcutConfigView(preferences: shortcutPreferences))

        configWindow = window
    }

    private func configureHotKeyManager() {
        let manager = GlobalHotKeyManager { [weak self] in
            Task { @MainActor [weak self] in
                self?.showQuickPastePanelFromShortcut()
            }
        }
        hotKeyManager = manager

        shortcutPreferences.onChange = { [weak self] configuration in
            self?.hotKeyManager?.register(configuration: configuration)
        }

        manager.register(configuration: shortcutPreferences.configuration)
    }

    private func configureCopyCommandMonitor() {
        copyCommandMonitor = CopyCommandMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.store.requestImmediateCheck()
            }
        }
    }

    @objc
    private func togglePanel(_ sender: AnyObject?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }

        guard let button = statusItem?.button, let panel else { return }

        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(sender)
            return
        }

        showPanel(panel, anchoredTo: button)
    }

    private func showStatusMenu() {
        guard let statusItem, let menu = statusMenu, let button = statusItem.button else { return }
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc
    private func openConfigWindow(_ sender: Any?) {
        guard let configWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        configWindow.center()
        configWindow.makeKeyAndOrderFront(nil)
    }

    private func showPanel(_ panel: NSPanel, anchoredTo button: NSStatusBarButton) {
        guard !isOpeningPanel else { return }
        isOpeningPanel = true

        positionPanel(panel, anchoredTo: button)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        // Retry once on the next runloop tick to avoid occasional first-click focus races.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if !panel.isVisible || !panel.isKeyWindow {
                self.positionPanel(panel, anchoredTo: button)
                panel.orderFrontRegardless()
                panel.makeKeyAndOrderFront(nil)
            }

            self.isOpeningPanel = false
        }
    }

    private func positionPanel(_ panel: NSPanel, anchoredTo button: NSStatusBarButton) {
        guard
            let buttonWindow = button.window,
            let screen = buttonWindow.screen ?? NSScreen.main
        else {
            panel.center()
            return
        }

        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = screen.visibleFrame

        let preferredX = buttonFrameOnScreen.midX - (panel.frame.width / 2)
        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - panel.frame.width
        let clampedX = min(max(preferredX, minX), maxX)

        let preferredY = buttonFrameOnScreen.minY - panel.frame.height - 8
        let minY = visibleFrame.minY
        let clampedY = max(preferredY, minY)

        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    private func showQuickPastePanelFromShortcut() {
        guard let quickPanel = quickPastePanel else { return }

        // Shortcut should only show the quick popup.
        panel?.orderOut(nil)

        quickPasteViewModel.setEntries(Array(store.entries.prefix(10)))
        positionQuickPastePanel(quickPanel)

        NSApp.activate(ignoringOtherApps: true)
        quickPanel.orderFrontRegardless()
        quickPanel.makeKeyAndOrderFront(nil)
    }

    private func positionQuickPastePanel(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let x = visibleFrame.midX - (panel.frame.width / 2)
        let y = visibleFrame.midY - (panel.frame.height / 2)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideQuickPastePanel() {
        quickPastePanel?.orderOut(nil)
    }

    private func activateSelectedQuickPasteEntry() {
        guard let selectedEntry = quickPasteViewModel.selectedEntry else {
            hideQuickPastePanel()
            return
        }

        insertEntryIntoFocusedApp(selectedEntry)
    }

    private func insertEntryIntoFocusedApp(_ entry: ClipboardEntry) {
        store.copyEntryToPasteboard(entry)
        hideQuickPastePanel()

        // Return focus to previous app and simulate Cmd+V.
        NSApp.hide(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.postCommandV()
        }
    }

    private func postCommandV() {
        guard ensureAccessibilityPermission() else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyCode: CGKeyCode = 9 // V
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

struct ShortcutConfiguration: Codable, Equatable {
    static let storageKey = "quickPasteShortcutConfiguration"
    static let defaultValue = ShortcutConfiguration(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    var keyCode: UInt32
    var modifiers: UInt32

    mutating func setModifier(_ mask: UInt32, enabled: Bool) {
        if enabled {
            modifiers |= mask
        } else {
            modifiers &= ~mask
        }
    }

    mutating func ensureAtLeastOneModifier() {
        if modifiers == 0 {
            modifiers = UInt32(cmdKey)
        }
    }

    var displayString: String {
        var parts: [String] = []

        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }

        let key = Self.keyTitle(for: keyCode)
        parts.append(key)
        return parts.joined(separator: " ")
    }

    private static func keyTitle(for keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        case UInt32(kVK_Space): return "Space"
        case UInt32(kVK_Return): return "Return"
        case UInt32(kVK_Tab): return "Tab"
        case UInt32(kVK_Delete): return "Delete"
        case UInt32(kVK_ForwardDelete): return "Forward Delete"
        case UInt32(kVK_Escape): return "Escape"
        case UInt32(kVK_LeftArrow): return "Left"
        case UInt32(kVK_RightArrow): return "Right"
        case UInt32(kVK_DownArrow): return "Down"
        case UInt32(kVK_UpArrow): return "Up"
        default:
            return "Key \(keyCode)"
        }
    }
}

@MainActor
final class ShortcutPreferences: ObservableObject {
    @Published var configuration: ShortcutConfiguration {
        didSet {
            var normalized = configuration
            normalized.ensureAtLeastOneModifier()
            if normalized != configuration {
                configuration = normalized
                return
            }

            persist()
            onChange?(configuration)
        }
    }

    var onChange: ((ShortcutConfiguration) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let loaded = Self.load(from: defaults) {
            var normalized = loaded
            normalized.ensureAtLeastOneModifier()
            configuration = normalized
        } else {
            configuration = .defaultValue
        }
    }

    private let defaults: UserDefaults

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(encoded, forKey: ShortcutConfiguration.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> ShortcutConfiguration? {
        guard let data = defaults.data(forKey: ShortcutConfiguration.storageKey) else { return nil }
        return try? JSONDecoder().decode(ShortcutConfiguration.self, from: data)
    }
}

private struct ShortcutConfigView: View {
    @ObservedObject var preferences: ShortcutPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Popup Shortcut")
                .font(.headline)

            ShortcutRecorderField(configuration: configurationBinding)
                .frame(height: 36)

            Text("Current: \(preferences.configuration.displayString)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Click the field, press your shortcut. Esc cancels recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private var configurationBinding: Binding<ShortcutConfiguration> {
        Binding(
            get: { preferences.configuration },
            set: { preferences.configuration = $0 }
        )
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var configuration: ShortcutConfiguration

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView(frame: .zero)
        view.onCapture = { [binding = $configuration] shortcut in
            binding.wrappedValue = shortcut
        }
        view.setConfiguration(configuration)
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.setConfiguration(configuration)
    }
}

private final class ShortcutRecorderNSView: NSView {
    var onCapture: ((ShortcutConfiguration) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var configuration: ShortcutConfiguration = .defaultValue
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        refreshLabel()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isRecording = true
            refreshLabel()
            updateAppearance()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isRecording = false
            refreshLabel()
            updateAppearance()
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        if Self.isModifierOnlyKeyCode(event.keyCode) {
            return
        }

        var captured = ShortcutConfiguration(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.carbonsModifiers(from: event.modifierFlags)
        )
        captured.ensureAtLeastOneModifier()
        onCapture?(captured)
        setConfiguration(captured)
        window?.makeFirstResponder(nil)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    func setConfiguration(_ configuration: ShortcutConfiguration) {
        self.configuration = configuration
        refreshLabel()
    }

    private func refreshLabel() {
        label.stringValue = isRecording ? "Press new shortcut..." : configuration.displayString
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let isFocused = window?.firstResponder === self
        layer?.borderColor = (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    private static func carbonsModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static func isModifierOnlyKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_CapsLock), UInt16(kVK_Function):
            return true
        default:
            return false
        }
    }
}

private final class GlobalHotKeyManager {
    private static let hotKeySignature: OSType = 0x4D554E49 // "MUNI"
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onHotKeyPressed: () -> Void

    init(onHotKeyPressed: @escaping () -> Void) {
        self.onHotKeyPressed = onHotKeyPressed
        installEventHandler()
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func register(configuration: ShortcutConfiguration) {
        unregister()

        let identifier = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr else { return status }

        guard identifier.signature == Self.hotKeySignature, identifier.id == Self.hotKeyID else {
            return noErr
        }

        DispatchQueue.main.async { [onHotKeyPressed] in
            onHotKeyPressed()
        }
        return noErr
    }
}

private final class CopyCommandMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onLikelyCopyOrCut: () -> Void

    init(onLikelyCopyOrCut: @escaping () -> Void) {
        self.onLikelyCopyOrCut = onLikelyCopyOrCut
        start()
    }

    deinit {
        stop()
    }

    private func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        guard key == "c" || key == "x" else { return }

        // Allow source app to publish pasteboard content first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [onLikelyCopyOrCut] in
            onLikelyCopyOrCut()
        }
    }
}

private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleHotKeyEvent(event)
}

private final class QuickPastePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEnter: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onEscape?()
        case 126: // Up
            onArrowUp?()
        case 125: // Down
            onArrowDown?()
        case 36, 76: // Return / Enter
            onEnter?()
        default:
            super.keyDown(with: event)
        }
    }
}
