import Testing
@testable import macmpv

struct AppUpdaterTests {
    /// Only packaged builds carry an update feed; anything else (tests,
    /// `swift run`, `make app`) must never replace itself with a release.
    @Test @MainActor func unpackagedBuildsNeverStartTheUpdater() {
        let updater = AppUpdater()
        #expect(!updater.isEnabled)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.automaticallyInstallsUpdates)
    }
}
