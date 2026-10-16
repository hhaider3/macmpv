import Foundation
import Observation
import Sparkle

/// Software updates through Sparkle. Packaged builds check the variant's feed
/// (SUFeedURL, written by package-dmg.sh) at launch and daily, download newer
/// releases from GitHub in the background, and install them when the app
/// quits. An update is accepted only if its EdDSA signature matches
/// SUPublicEDKey, so a replaced GitHub asset alone cannot ship code.
///
/// Development builds (`swift run`, `make app`) carry no feed, so they never
/// replace themselves with a release. MACMPV_UPDATE_FEED overrides the feed
/// for testing an update end to end.
@MainActor
@Observable
final class AppUpdater: NSObject {
    private(set) var canCheckForUpdates = false
    private(set) var isEnabled = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private let feedOverride: String?

    override init() {
        let override = ProcessInfo.processInfo.environment["MACMPV_UPDATE_FEED"]
        feedOverride = override?.isEmpty == false ? override : nil
        super.init()

        let bundledFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil,
              feedOverride != nil || bundledFeed?.isEmpty == false else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        isEnabled = true
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
    }

    var automaticallyInstallsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let override = ProcessInfo.processInfo.environment["MACMPV_UPDATE_FEED"]
        return override?.isEmpty == false ? override : nil
    }
}
