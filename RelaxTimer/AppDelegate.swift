import Cocoa
import SwiftUI
import Sparkle

// MARK: - AppDelegate (Menu bar app)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUUpdaterDelegate {

    private var statusItem: NSStatusItem!
    private let scheduler = RelaxScheduler()

    // Keep menus/items so we can update checkmarks and titles
    private let menu = NSMenu()

    private let intervalMenuItem = NSMenuItem(title: "Set Count Down", action: nil, keyEquivalent: "")
    private let breakMenuItem = NSMenuItem(title: "Set Break Time", action: nil, keyEquivalent: "")

    private let pauseResumeItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "Reset", action: nil, keyEquivalent: "")
    private let showNowItem = NSMenuItem(title: "Relax Now", action: nil, keyEquivalent: "")

    // NEW: update item (Latest / Update Now)
    private let updateItem = NSMenuItem(title: "Latest", action: nil, keyEquivalent: "")

    private let quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")

    // If user manually paused, we should NOT auto-resume on unlock
    private var wasPausedByLockEvent: Bool = false

    // Sparkle updater (embedded in your app)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private var updateProbeTimer: Timer?
    private var updateAvailable: Bool = false

    func menuWillOpen(_ menu: NSMenu) {
        // Always refresh states right before showing the dropdown
        refreshCheckmarks()
        refreshPauseResumeTitle()
    }

    // We manually control enabled/disabled (grey + not clickable)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // When paused, disable Reset and Relax Now (grey + not clickable)
        if menuItem === resetItem { return !scheduler.isPaused }
        if menuItem === showNowItem { return !scheduler.isPaused }

        // Update button: only clickable when update exists
        if menuItem === updateItem { return updateAvailable }

        // Everything else stays enabled
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

        // Start Sparkle updater
        _ = updaterController
        try? updaterController.updater.start()

        // Auto check for updates (silent)
        startAutoUpdateChecks()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // SF Symbols eye icon
            button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "RelaxTimer")
            button.imagePosition = .imageLeft
            button.title = " 20:00"
        }

        statusItem.menu = menu
    }

    private func updateStatusTitle(_ display: String) {
        guard let button = statusItem.button else { return }

        let text = " \(display)"

        // Monospaced digits so the eye doesn't shift during 20:00 -> 19:59, etc.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Menu

    private func setupMenu() {
        // Interval submenu
        let intervalSubmenu = NSMenu()
        for m in RelaxScheduler.allowedIntervalMinutes {
            let item = NSMenuItem(title: "\(m) minutes", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m
            intervalSubmenu.addItem(item)
        }
        intervalMenuItem.submenu = intervalSubmenu

        // Break duration submenu
        let breakSubmenu = NSMenu()
        for s in RelaxScheduler.allowedRelaxSeconds {
            let item = NSMenuItem(title: "\(s) seconds", action: #selector(setBreak(_:)), keyEquivalent: "")
            item.target = self
            item.tag = s
            breakSubmenu.addItem(item)
        }
        breakMenuItem.submenu = breakSubmenu

        pauseResumeItem.target = self
        pauseResumeItem.action = #selector(togglePauseResume(_:))

        resetItem.target = self
        resetItem.action = #selector(resetCountdown(_:))

        showNowItem.target = self
        showNowItem.action = #selector(showNow(_:))

        // Update item target/action
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
        menu.addItem(NSMenuItem.separator())
        menu.addItem(pauseResumeItem)
        menu.addItem(resetItem)
        menu.addItem(showNowItem)

        // NEW section line between Relax Now and Update button
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
    }

    private func refreshPauseResumeTitle() {
        pauseResumeItem.title = scheduler.isPaused ? "Resume" : "Pause"

        // When paused, disable Reset and Relax Now (greyed out)
        resetItem.isEnabled = !scheduler.isPaused
        showNowItem.isEnabled = !scheduler.isPaused
    }

    private func refreshEnabledStates() {
        // Requirement: when paused, make Reset and Relax Now unavailable
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
        scheduler.setIntervalMinutes(sender.tag)   // resets countdown immediately
        refreshCheckmarks()
    }

    @objc private func setBreak(_ sender: NSMenuItem) {
        scheduler.setRelaxSeconds(sender.tag)      // does NOT reset countdown
        refreshCheckmarks()
    }

    @objc private func togglePauseResume(_ sender: NSMenuItem) {
        // Manual toggle: clear lock-paused flag
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

    // NEW: Update button
    @objc private func updateNow(_ sender: NSMenuItem) {
        // This opens Sparkle UI and performs automatic install/relaunch if an update exists.
        updaterController.updater.checkForUpdates()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Auto update checks (silent)

    private func startAutoUpdateChecks() {
        // First silent check shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.probeForUpdateSilently()
        }

        // Then every 6 hours
        updateProbeTimer?.invalidate()
        updateProbeTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.probeForUpdateSilently()
        }
        if let t = updateProbeTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func probeForUpdateSilently() {
        // Sparkle determines update availability via your appcast feed (SUFeedURL in Info.plist).
        // This performs a background check (no UI).
        updaterController.updater.checkForUpdatesInBackground()
    }

    // MARK: - Sparkle delegate (drives Latest / Update Now)

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
        // If feed is missing/misconfigured, treat as no update
        updateAvailable = false
        DispatchQueue.main.async { [weak self] in
            self?.refreshUpdateUI()
        }
    }

    // MARK: - Lock / Unlock detection

    private func observeLockEvents() {
        let workspaceNC = NSWorkspace.shared.notificationCenter

        // This reliably fires when the screen goes to sleep (often when locked)
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

        // More accurate: actual lock/unlock (distributed notifications)
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
        // If already paused by user, don't change flag
        if !scheduler.isPaused {
            wasPausedByLockEvent = true
            scheduler.pause()
            refreshPauseResumeTitle()
            refreshEnabledStates()
        }
    }

    @objc private func screenDidWake() {
        // Wake does not always mean unlocked; unlock handler will resume if needed
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

    // Settings (persisted)
    private(set) var intervalMinutes: Int
    private(set) var relaxSeconds: Int

    private enum DefaultsKey {
        static let intervalMinutes = "RelaxTimer.intervalMinutes"
        static let relaxSeconds = "RelaxTimer.relaxSeconds"
    }

    // State
    private(set) var isPaused: Bool = false
    private var secondsRemaining: Int = 0
    private var timer: Timer?

    // Overlay
    private var overlayWindows: [NSWindow] = []
    private var requestFadeWorkItem: DispatchWorkItem?
    private var finalizeHideWorkItem: DispatchWorkItem?
    private let fadeDuration: TimeInterval = 1

    // Callback to update menu bar title
    var onTick: ((String) -> Void)?

    init() {
        // Defaults are 20 minutes and 20 seconds
        let savedInterval = UserDefaults.standard.object(forKey: DefaultsKey.intervalMinutes) as? Int
        let savedRelax = UserDefaults.standard.object(forKey: DefaultsKey.relaxSeconds) as? Int

        intervalMinutes = savedInterval ?? 20
        relaxSeconds = savedRelax ?? 20

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
        // Reset to full time based on current setting
        secondsRemaining = intervalMinutes * 60

        if isPaused {
            // stay paused, keep showing "Pause"
            tickUI()
            return
        }

        // Restart the timer so it doesn't tick immediately
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

        // reset timer immediately
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

        // do not reset countdown
        tickUI()
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

    // MARK: - Overlay behavior (fade in/out + quit relax)

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
            onQuitRelax: { [weak self] in
                self?.dismissOverlayWithFadeThenRestart()
            }
        )

        // Do NOT schedule fade here. The view will fade itself when it shows 0.
        // Only hide after duration + fadeDuration, so the fade has time to finish.
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

    private func showOverlay(durationSeconds: Int, fadeDuration: TimeInterval, onQuitRelax: @escaping () -> Void) {
        let screens = NSScreen.screens
        if screens.isEmpty { return }

        overlayWindows = screens.map { screen in
            let view = RelaxOverlayView(
                durationSeconds: durationSeconds,
                fadeDuration: fadeDuration,
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

// MARK: - Overlay View (no main interface needed)

struct RelaxOverlayView: View {

    let durationSeconds: Int
    let fadeDuration: TimeInterval
    let onQuitRelax: () -> Void

    @State private var secondsLeft: Int
    @State private var overlayOpacity: Double = 0.0
    @State private var didAutoFadeOut: Bool = false

    init(durationSeconds: Int, fadeDuration: TimeInterval, onQuitRelax: @escaping () -> Void) {
        self.durationSeconds = max(1, durationSeconds)
        self.fadeDuration = max(0.1, fadeDuration)
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
                    colors: [
                        Color(red: 46/255, green: 46/255, blue: 46/255),
                        Color(red: 32/255, green: 32/255, blue: 32/255)
                    ],
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

                // Fade ONLY when the UI reaches 0
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
