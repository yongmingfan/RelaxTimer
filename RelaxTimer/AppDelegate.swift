import Cocoa
import SwiftUI
import Sparkle

enum RelaxColorPreset: Int, CaseIterable {
    case currentDark = 0
    case sageGreen = 1
    case warmAmber = 2
    case softBlue = 3

    var menuTitle: String {
        switch self {
        case .currentDark:
            return "Midnight"
        case .sageGreen:
            return "Forest"
        case .warmAmber:
            return "Amber"
        case .softBlue:
            return "Ocean"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .currentDark:
            return [
                Color(red: 46/255, green: 46/255, blue: 46/255),
                Color(red: 32/255, green: 32/255, blue: 32/255)
            ]
        case .sageGreen:
            return [
                Color(red: 70/255, green: 88/255, blue: 78/255),
                Color(red: 45/255, green: 60/255, blue: 53/255)
            ]
        case .warmAmber:
            return [
                Color(red: 92/255, green: 76/255, blue: 55/255),
                Color(red: 64/255, green: 51/255, blue: 38/255)
            ]
        case .softBlue:
            return [
                Color(red: 67/255, green: 82/255, blue: 97/255),
                Color(red: 42/255, green: 54/255, blue: 66/255)
            ]
        }
    }
}

// MARK: - AppDelegate (Menu bar app)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUUpdaterDelegate {

    private var statusItem: NSStatusItem!
    private let scheduler = RelaxScheduler()

    // Keep menus/items so we can update checkmarks and titles
    private let menu = NSMenu()

    private let intervalMenuItem = NSMenuItem(title: "Set Count Down", action: nil, keyEquivalent: "")
    private let breakMenuItem = NSMenuItem(title: "Set Break Time", action: nil, keyEquivalent: "")
    private let relaxColorMenuItem = NSMenuItem(title: "Set Relax Color", action: nil, keyEquivalent: "")

    private let pauseResumeItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "Reset", action: nil, keyEquivalent: "")
    private let showNowItem = NSMenuItem(title: "Relax Now", action: nil, keyEquivalent: "")

    private let updateItem = NSMenuItem(title: "Latest", action: nil, keyEquivalent: "")

    private let quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")

    private var wasPausedByLockEvent: Bool = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private var updateProbeTimer: Timer?
    private var updateAvailable: Bool = false

    func menuWillOpen(_ menu: NSMenu) {
        refreshCheckmarks()
        refreshPauseResumeTitle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === resetItem { return !scheduler.isPaused }
        if menuItem === showNowItem { return !scheduler.isPaused }
        if menuItem === updateItem { return updateAvailable }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        observeLockEvents()

        scheduler.onTick = { [weak self] display in
            DispatchQueue.main.async {
                self?.updateStatusTitle(display)
                self?.refreshCheckmarks()
                self?.refreshPauseResumeTitle()
                self?.refreshEnabledStates()
            }
        }

        scheduler.start()

        _ = updaterController
        try? updaterController.updater.start()

        startAutoUpdateChecks()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "RelaxTimer")
            button.imagePosition = .imageLeft
            button.title = " 20:00"
        }

        statusItem.menu = menu
    }

    private func updateStatusTitle(_ display: String) {
        guard let button = statusItem.button else { return }

        let text = " \(display)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Menu

    private func setupMenu() {
        let intervalSubmenu = NSMenu()
        for m in RelaxScheduler.allowedIntervalMinutes {
            let item = NSMenuItem(title: "\(m) minutes", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m
            intervalSubmenu.addItem(item)
        }
        intervalMenuItem.submenu = intervalSubmenu

        let breakSubmenu = NSMenu()
        for s in RelaxScheduler.allowedRelaxSeconds {
            let item = NSMenuItem(title: "\(s) seconds", action: #selector(setBreak(_:)), keyEquivalent: "")
            item.target = self
            item.tag = s
            breakSubmenu.addItem(item)
        }
        breakMenuItem.submenu = breakSubmenu

        let colorSubmenu = NSMenu()
        for preset in RelaxColorPreset.allCases {
            let item = NSMenuItem(title: preset.menuTitle, action: #selector(setRelaxColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            colorSubmenu.addItem(item)
        }
        relaxColorMenuItem.submenu = colorSubmenu

        pauseResumeItem.target = self
        pauseResumeItem.action = #selector(togglePauseResume(_:))

        resetItem.target = self
        resetItem.action = #selector(resetCountdown(_:))

        showNowItem.target = self
        showNowItem.action = #selector(showNow(_:))

        updateItem.target = self
        updateItem.action = #selector(updateNow(_:))
        updateItem.title = "Latest"
        updateItem.isEnabled = false
        updateAvailable = false

        quitItem.target = self
        quitItem.action = #selector(quitApp(_:))

        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(intervalMenuItem)
        menu.addItem(breakMenuItem)
        menu.addItem(relaxColorMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(pauseResumeItem)
        menu.addItem(resetItem)
        menu.addItem(showNowItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        refreshCheckmarks()
        refreshPauseResumeTitle()
        refreshEnabledStates()
        refreshUpdateUI()
    }

    private func refreshCheckmarks() {
        if let intervalSubmenu = intervalMenuItem.submenu {
            for item in intervalSubmenu.items {
                item.state = (item.tag == scheduler.intervalMinutes) ? .on : .off
            }
        }

        if let breakSubmenu = breakMenuItem.submenu {
            for item in breakSubmenu.items {
                item.state = (item.tag == scheduler.relaxSeconds) ? .on : .off
            }
        }

        if let colorSubmenu = relaxColorMenuItem.submenu {
            for item in colorSubmenu.items {
                item.state = (item.tag == scheduler.relaxColorPreset.rawValue) ? .on : .off
            }
        }
    }

    private func refreshPauseResumeTitle() {
        pauseResumeItem.title = scheduler.isPaused ? "Resume" : "Pause"
        resetItem.isEnabled = !scheduler.isPaused
        showNowItem.isEnabled = !scheduler.isPaused
    }

    private func refreshEnabledStates() {
        resetItem.isEnabled = !scheduler.isPaused
        showNowItem.isEnabled = !scheduler.isPaused
    }

    private func refreshUpdateUI() {
        if updateAvailable {
            updateItem.title = "Update Now"
            updateItem.isEnabled = true
        } else {
            updateItem.title = "Latest"
            updateItem.isEnabled = false
        }
        menu.update()
    }

    // MARK: - Menu actions

    @objc private func setInterval(_ sender: NSMenuItem) {
        scheduler.setIntervalMinutes(sender.tag)
        refreshCheckmarks()
    }

    @objc private func setBreak(_ sender: NSMenuItem) {
        scheduler.setRelaxSeconds(sender.tag)
        refreshCheckmarks()
    }

    @objc private func setRelaxColor(_ sender: NSMenuItem) {
        guard let preset = RelaxColorPreset(rawValue: sender.tag) else { return }
        scheduler.setRelaxColorPreset(preset)
        refreshCheckmarks()
    }

    @objc private func togglePauseResume(_ sender: NSMenuItem) {
        wasPausedByLockEvent = false

        if scheduler.isPaused {
            scheduler.resume()
        } else {
            scheduler.pause()
        }
        refreshPauseResumeTitle()
        refreshEnabledStates()
        menu.update()
    }

    @objc private func resetCountdown(_ sender: NSMenuItem) {
        if scheduler.isPaused { return }
        scheduler.resetCountdownToFull()
        refreshEnabledStates()
    }

    @objc private func showNow(_ sender: NSMenuItem) {
        if scheduler.isPaused { return }
        scheduler.showNow()
    }

    @objc private func updateNow(_ sender: NSMenuItem) {
        updaterController.updater.checkForUpdates()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Auto update checks (silent)

    private func startAutoUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.probeForUpdateSilently()
        }

        updateProbeTimer?.invalidate()
        updateProbeTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.probeForUpdateSilently()
        }
        if let t = updateProbeTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func probeForUpdateSilently() {
        updaterController.updater.checkForUpdatesInBackground()
    }

    // MARK: - Sparkle delegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateUI()
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateAvailable = false
        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateUI()
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateAvailable = false
        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateUI()
        }
    }

    // MARK: - Lock / Unlock detection

    private func observeLockEvents() {
        let workspaceNC = NSWorkspace.shared.notificationCenter

        workspaceNC.addObserver(
            self,
            selector: #selector(screenDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        workspaceNC.addObserver(
            self,
            selector: #selector(screenDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func screenDidSleep() {
        if !scheduler.isPaused {
            wasPausedByLockEvent = true
            scheduler.pause()
            refreshPauseResumeTitle()
            refreshEnabledStates()
        }
    }

    @objc private func screenDidWake() {
    }

    @objc private func screenLocked() {
        if !scheduler.isPaused {
            wasPausedByLockEvent = true
            scheduler.pause()
            refreshPauseResumeTitle()
            refreshEnabledStates()
        }
    }

    @objc private func screenUnlocked() {
        if wasPausedByLockEvent {
            wasPausedByLockEvent = false
            scheduler.resume()
            refreshPauseResumeTitle()
            refreshEnabledStates()
        }
    }
}

// MARK: - Scheduler + Overlay

private extension Notification.Name {
    static let relaxOverlayFadeOut = Notification.Name("RelaxOverlayFadeOut")
}

final class RelaxScheduler {

    static let allowedIntervalMinutes: [Int] = [10, 20, 30]
    static let allowedRelaxSeconds: [Int] = [20, 30, 45, 60]

    private(set) var intervalMinutes: Int
    private(set) var relaxSeconds: Int
    private(set) var relaxColorPreset: RelaxColorPreset

    private enum DefaultsKey {
        static let intervalMinutes = "RelaxTimer.intervalMinutes"
        static let relaxSeconds = "RelaxTimer.relaxSeconds"
        static let relaxColorPreset = "RelaxTimer.relaxColorPreset"
    }

    private(set) var isPaused: Bool = false
    private var secondsRemaining: Int = 0
    private var timer: Timer?

    private var overlayWindows: [NSWindow] = []
    private var requestFadeWorkItem: DispatchWorkItem?
    private var finalizeHideWorkItem: DispatchWorkItem?
    private let fadeDuration: TimeInterval = 1

    var onTick: ((String) -> Void)?

    init() {
        let savedInterval = UserDefaults.standard.object(forKey: DefaultsKey.intervalMinutes) as? Int
        let savedRelax = UserDefaults.standard.object(forKey: DefaultsKey.relaxSeconds) as? Int
        let savedColorRawValue = UserDefaults.standard.object(forKey: DefaultsKey.relaxColorPreset) as? Int

        intervalMinutes = savedInterval ?? 20
        relaxSeconds = savedRelax ?? 20
        relaxColorPreset = RelaxColorPreset(rawValue: savedColorRawValue ?? RelaxColorPreset.currentDark.rawValue) ?? .currentDark

        if !Self.allowedIntervalMinutes.contains(intervalMinutes) { intervalMinutes = 20 }
        if !Self.allowedRelaxSeconds.contains(relaxSeconds) { relaxSeconds = 20 }

        secondsRemaining = intervalMinutes * 60
    }

    func start() {
        isPaused = false
        stopTimer()
        secondsRemaining = intervalMinutes * 60
        tickUI()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func pause() {
        isPaused = true
        stopTimer()
        cancelOverlayWork()
        hideOverlay()
        tickUI()
    }

    func resume() {
        isPaused = false
        stopTimer()
        tickUI()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func resetCountdownToFull() {
        secondsRemaining = intervalMinutes * 60

        if isPaused {
            tickUI()
            return
        }

        stopTimer()
        tickUI()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func setIntervalMinutes(_ minutes: Int) {
        intervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: DefaultsKey.intervalMinutes)

        if isPaused {
            secondsRemaining = intervalMinutes * 60
            tickUI()
        } else {
            start()
        }
    }

    func setRelaxSeconds(_ seconds: Int) {
        relaxSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: DefaultsKey.relaxSeconds)
        tickUI()
    }

    func setRelaxColorPreset(_ preset: RelaxColorPreset) {
        relaxColorPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: DefaultsKey.relaxColorPreset)
    }

    func showNow() {
        if isPaused { return }
        showOverlayThenRestart()
    }

    // MARK: - Tick

    private func tick() {
        if isPaused { return }

        if secondsRemaining > 0 { secondsRemaining -= 1 }
        tickUI()

        if secondsRemaining == 0 { showOverlayThenRestart() }
    }

    private func tickUI() {
        if isPaused {
            onTick?("Pause")
            return
        }
        let m = max(0, secondsRemaining) / 60
        let s = max(0, secondsRemaining) % 60
        onTick?(String(format: "%02d:%02d", m, s))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Overlay behavior

    private func cancelOverlayWork() {
        requestFadeWorkItem?.cancel()
        requestFadeWorkItem = nil
        finalizeHideWorkItem?.cancel()
        finalizeHideWorkItem = nil
    }

    private func requestOverlayFadeOut() {
        NotificationCenter.default.post(name: .relaxOverlayFadeOut, object: nil)
    }

    private func showOverlayThenRestart() {
        stopTimer()
        cancelOverlayWork()

        let duration = max(1, relaxSeconds)

        showOverlay(
            durationSeconds: duration,
            fadeDuration: fadeDuration,
            preset: relaxColorPreset,
            onQuitRelax: { [weak self] in
                self?.dismissOverlayWithFadeThenRestart()
            }
        )

        let finalizeWork = DispatchWorkItem { [weak self] in
            self?.hideOverlay()
            self?.start()
        }
        finalizeHideWorkItem = finalizeWork
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(duration) + fadeDuration, execute: finalizeWork)
    }

    private func dismissOverlayWithFadeThenRestart() {
        cancelOverlayWork()
        requestOverlayFadeOut()

        let finalizeWork = DispatchWorkItem { [weak self] in
            self?.hideOverlay()
            self?.start()
        }
        finalizeHideWorkItem = finalizeWork
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: finalizeWork)
    }

    private func showOverlay(durationSeconds: Int, fadeDuration: TimeInterval, preset: RelaxColorPreset, onQuitRelax: @escaping () -> Void) {
        let screens = NSScreen.screens
        if screens.isEmpty { return }

        overlayWindows = screens.map { screen in
            let view = RelaxOverlayView(
                durationSeconds: durationSeconds,
                fadeDuration: fadeDuration,
                preset: preset,
                onQuitRelax: onQuitRelax
            )

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false
            window.contentView = NSHostingView(rootView: view)

            window.makeKeyAndOrderFront(nil)
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideOverlay() {
        for w in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
    }
}

// MARK: - Overlay View

struct RelaxOverlayView: View {

    let durationSeconds: Int
    let fadeDuration: TimeInterval
    let preset: RelaxColorPreset
    let onQuitRelax: () -> Void

    @State private var secondsLeft: Int
    @State private var overlayOpacity: Double = 0.0
    @State private var didAutoFadeOut: Bool = false

    init(durationSeconds: Int, fadeDuration: TimeInterval, preset: RelaxColorPreset, onQuitRelax: @escaping () -> Void) {
        self.durationSeconds = max(1, durationSeconds)
        self.fadeDuration = max(0.1, fadeDuration)
        self.preset = preset
        self.onQuitRelax = onQuitRelax
        _secondsLeft = State(initialValue: max(1, durationSeconds))
    }

    private var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(durationSeconds - secondsLeft) / Double(durationSeconds)
    }

    var body: some View {
        GeometryReader { geo in

            let cardWidth = min(geo.size.width * 0.42, 760)
            let ringSize = cardWidth * 0.45
            let titleSize = cardWidth * 0.085
            let descSize = cardWidth * 0.035
            let timerSize = ringSize * 0.45
            let buttonSize = cardWidth * 0.04

            ZStack {
                LinearGradient(
                    colors: preset.gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: cardWidth * 0.05) {

                    Text("Take a breath")
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))

                    Text("Look away from the screen and relax your eyes.")
                        .font(.system(size: descSize))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: cardWidth * 0.75)

                    ZStack {

                        Circle()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 12)

                        Circle()
                            .trim(from: 0, to: max(0, min(1, progress)))
                            .stroke(
                                Color.white.opacity(0.85),
                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        Text("\(secondsLeft)")
                            .font(.system(size: timerSize, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .frame(width: ringSize, height: ringSize)

                    Button {
                        onQuitRelax()
                    } label: {
                        Text("End break")
                            .font(.system(size: buttonSize, weight: .semibold))
                            .padding(.horizontal, 26)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.white.opacity(0.18))
                    .foregroundColor(.white)
                }
                .padding(cardWidth * 0.12)
                .frame(width: cardWidth)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(Color.white.opacity(0.12))
                        )
                        .shadow(color: .black.opacity(0.35), radius: 40, x: 0, y: 15)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(overlayOpacity)
        .onAppear {
            withAnimation(.easeInOut(duration: fadeDuration)) {
                overlayOpacity = 1.0
            }

            let t = Timer(timeInterval: 1.0, repeats: true) { timer in
                if secondsLeft > 0 {
                    secondsLeft -= 1
                }

                if secondsLeft == 0 && !didAutoFadeOut {
                    didAutoFadeOut = true
                    withAnimation(.easeInOut(duration: fadeDuration)) {
                        overlayOpacity = 0.0
                    }
                    timer.invalidate()
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
        .onReceive(NotificationCenter.default.publisher(for: .relaxOverlayFadeOut)) { _ in
            withAnimation(.easeInOut(duration: fadeDuration)) {
                overlayOpacity = 0.0
            }
        }
    }
}
