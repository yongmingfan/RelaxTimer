import Cocoa
import SwiftUI

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

struct LatestReleaseInfo: Decodable {
    let version: String
    let build: String
    let pkg_url: String
}

final class UpdateManager {

    private let metadataURL = URL(string: "https://yongmingfan.github.io/RelaxTimer/latest.json")!

    func checkForUpdate(completion: @escaping (Result<LatestReleaseInfo?, Error>) -> Void) {
        let request = URLRequest(url: metadataURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "UpdateManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No response data received."
                ])))
                return
            }

            do {
                let remote = try JSONDecoder().decode(LatestReleaseInfo.self, from: data)

                let localVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let localBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

                if Self.isRemoteNewer(remoteVersion: remote.version, remoteBuild: remote.build, localVersion: localVersion, localBuild: localBuild) {
                    completion(.success(remote))
                } else {
                    completion(.success(nil))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func downloadAndOpenInstaller(from pkgURLString: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let pkgURL = URL(string: pkgURLString) else {
            completion(.failure(NSError(domain: "UpdateManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid package URL."
            ])))
            return
        }

        let request = URLRequest(url: pkgURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)

        URLSession.shared.downloadTask(with: request) { tempURL, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let tempURL = tempURL else {
                completion(.failure(NSError(domain: "UpdateManager", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Downloaded package file is missing."
                ])))
                return
            }

            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(pkgURL.lastPathComponent)

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)

                DispatchQueue.main.async {
                    NSWorkspace.shared.open(destinationURL)
                    completion(.success(()))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func isRemoteNewer(remoteVersion: String, remoteBuild: String, localVersion: String, localBuild: String) -> Bool {
        let versionComparison = remoteVersion.compare(localVersion, options: .numeric)

        if versionComparison == .orderedDescending {
            return true
        }

        if versionComparison == .orderedAscending {
            return false
        }

        let remoteBuildInt = Int(remoteBuild) ?? 0
        let localBuildInt = Int(localBuild) ?? 0
        return remoteBuildInt > localBuildInt
    }
}

// MARK: - AppDelegate (Menu bar app)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let scheduler = RelaxScheduler()
    private let updateManager = UpdateManager()

    private let menu = NSMenu()

    private let intervalMenuItem = NSMenuItem(title: "Set Count Down", action: nil, keyEquivalent: "")
    private let breakMenuItem = NSMenuItem(title: "Set Break Time", action: nil, keyEquivalent: "")
    private let relaxColorMenuItem = NSMenuItem(title: "Set Relax Color", action: nil, keyEquivalent: "")

    private let pauseResumeItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "Reset", action: nil, keyEquivalent: "")
    private let showNowItem = NSMenuItem(title: "Relax Now", action: nil, keyEquivalent: "")

    private let updateItem = NSMenuItem(title: "Update", action: nil, keyEquivalent: "")
    private let versionItem = NSMenuItem(title: "Version", action: nil, keyEquivalent: "")

    private let quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")

    private var wasPausedByLockEvent: Bool = false
    private var isUpdating: Bool = false

    func menuWillOpen(_ menu: NSMenu) {
        refreshCheckmarks()
        refreshPauseResumeTitle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === resetItem { return !scheduler.isPaused }
        if menuItem === showNowItem { return !scheduler.isPaused }
        if menuItem === versionItem { return false }
        if menuItem === updateItem { return !isUpdating }
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
        updateItem.action = #selector(checkForUpdate(_:))
        updateItem.title = "Update"
        updateItem.isEnabled = true

        versionItem.target = nil
        versionItem.action = nil
        versionItem.title = "Version: \(appVersionString())"
        versionItem.isEnabled = false

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
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        refreshCheckmarks()
        refreshPauseResumeTitle()
        refreshEnabledStates()
    }

    private func appVersionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = style
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func askInstallUpdate(version: String, pkgURL: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Update Available"
            alert.informativeText = "Version \(version) is available. Download and install now?"
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.startDownloadAndInstall(pkgURL: pkgURL)
            } else {
                self.isUpdating = false
                self.updateItem.title = "Update"
                self.menu.update()
            }
        }
    }

    private func startDownloadAndInstall(pkgURL: String) {
        DispatchQueue.main.async {
            self.updateItem.title = "Downloading..."
            self.menu.update()
        }

        updateManager.downloadAndOpenInstaller(from: pkgURL) { [weak self] result in
            guard let self = self else { return }

            DispatchQueue.main.async {
                self.isUpdating = false
                self.updateItem.title = "Update"
                self.menu.update()
            }

            switch result {
            case .success:
                self.showAlert(
                    title: "Installer Opened",
                    message: "The installer has been opened. Follow the installer steps to complete the update."
                )
            case .failure(let error):
                self.showAlert(
                    title: "Update Failed",
                    message: error.localizedDescription,
                    style: .warning
                )
            }
        }
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

    @objc private func checkForUpdate(_ sender: NSMenuItem) {
        if isUpdating { return }

        isUpdating = true
        updateItem.title = "Checking..."
        menu.update()

        updateManager.checkForUpdate { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let releaseInfo):
                if let releaseInfo = releaseInfo {
                    self.askInstallUpdate(version: releaseInfo.version, pkgURL: releaseInfo.pkg_url)
                } else {
                    DispatchQueue.main.async {
                        self.isUpdating = false
                        self.updateItem.title = "Update"
                        self.menu.update()
                        self.showAlert(title: "No Available Update", message: "You are already using the latest version.")
                    }
                }

            case .failure(let error):
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.updateItem.title = "Update"
                    self.menu.update()
                    self.showAlert(title: "Update Check Failed", message: error.localizedDescription, style: .warning)
                }
            }
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
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
