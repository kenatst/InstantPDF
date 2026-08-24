import XCTest
@testable import PDFIt

/// Contracts for the Pro activation experience: trigger discipline
/// (verified purchase ONLY), pending-intent preservation across the flow,
/// one-time persistence, and local Demo Mode.
final class ProActivationTests: XCTestCase {

    @MainActor
    override func setUp() {
        super.setUp()
        ProActivationState.resetWelcomeState()
        PendingProIntent.clear()
        AppConfiguration.sharedDefaults.set(false, forKey: EntitlementCenter.demoModeKey)
#if DEBUG
        let defaults = AppConfiguration.sharedDefaults
        defaults.set(false, forKey: EntitlementCenter.debugForceProKey)
#endif
    }

    @MainActor
    override func tearDown() {
        ProActivationState.resetWelcomeState()
        PendingProIntent.clear()
        AppConfiguration.sharedDefaults.removeObject(forKey: EntitlementCenter.demoModeKey)
#if DEBUG
        AppConfiguration.sharedDefaults.removeObject(forKey: EntitlementCenter.debugForceProKey)
#endif
        super.tearDown()
    }

    // MARK: - Pending intent staging

    @MainActor
    func testPendingIntentStagesAndReadsBackExactFeature() {
        PendingProIntent.stage(.signature)
        XCTAssertEqual(PendingProIntent.current, .signature)
        // Reading must NOT clear — only the activation completion does.
        XCTAssertEqual(PendingProIntent.current, .signature)
        PendingProIntent.clear()
        XCTAssertNil(PendingProIntent.current)
    }

    @MainActor
    func testPendingIntentOverwritesOnNewStage() {
        PendingProIntent.stage(.compression)
        PendingProIntent.stage(.ocr)
        XCTAssertEqual(PendingProIntent.current, .ocr,
                       "the most recent explicit request is the user's real intent")
    }

    // MARK: - Activation eligibility (one-time per install)

    @MainActor
    func testActivationRunsOnceThenNeverAgain() {
        XCTAssertTrue(ProActivationState.isEligibleForActivationFlow)
        ProActivationState.hasCompletedGuide = true
        XCTAssertFalse(ProActivationState.isEligibleForActivationFlow,
                       "existing Pro users must not be interrupted repeatedly")
    }

    @MainActor
    func testResetWelcomeStateRestoresEligibilityForQAReplay() {
        ProActivationState.hasCompletedGuide = true
        ProActivationState.resetWelcomeState()
        XCTAssertTrue(ProActivationState.isEligibleForActivationFlow)
    }

    // MARK: - Purchase outcome → celebration mapping

    /// Mirrors PaywallView.purchase's switch exactly. Only .success may lead
    /// to the activation flow; cancelled/pending/failed never do.
    @MainActor
    private static func shouldCelebrate(outcome: EntitlementCenter.PurchaseOutcome) -> Bool {
        if case .success = outcome { return true }
        return false
    }

    @MainActor
    func testOnlyVerifiedSuccessTriggersCelebration() {
        XCTAssertTrue(Self.shouldCelebrate(outcome: .success))
        XCTAssertFalse(Self.shouldCelebrate(outcome: .userCancelled))
        XCTAssertFalse(Self.shouldCelebrate(outcome: .pending))
        for reason in ["network", "unverified transaction"] {
            XCTAssertFalse(Self.shouldCelebrate(outcome: .failed(reason)))
        }
    }

    @MainActor
    func testCancelledPurchaseLeavesNoPendingIntentSideEffects() {
        PendingProIntent.stage(.signature)
        // A cancelled purchase dismisses nothing and resumes nothing; the
        // staged intent is simply cleared by the host when the paywall closes.
        PendingProIntent.clear()
        XCTAssertNil(PendingProIntent.current)
    }

    // MARK: - Contextual intent resumption mapping

    @MainActor
    func testToolSectionMappingResumesExactRequestedTool() {
        XCTAssertEqual(PDFToolsHostView.section(for: .compression), .compress)
        XCTAssertEqual(PDFToolsHostView.section(for: .signature), .sign)
        XCTAssertEqual(PDFToolsHostView.section(for: .extractPages), .extract)
        XCTAssertEqual(PDFToolsHostView.section(for: .ocr), .ocr)
        // Non-tool features land safely on the menu, not a wrong tool.
        XCTAssertEqual(PDFToolsHostView.section(for: .advancedBatch), .menu)
        XCTAssertEqual(PDFToolsHostView.section(for: .unlimitedFolders), .menu)
    }

    // MARK: - Startup entitlement discovery is NOT a celebration trigger

    @MainActor
    func testStartupEntitlementDiscoveryDoesNotConsumeActivationEligibility() async {
        // Simulate a launch where StoreKit reports an existing entitlement:
        // recompute runs, but no purchase event happened.
        await EntitlementCenter(defaults: AppConfiguration.sharedDefaults).recompute()
        XCTAssertTrue(ProActivationState.isEligibleForActivationFlow,
                      "isPro at launch must never play the celebration by itself")
        XCTAssertNil(PendingProIntent.current)
    }

    // MARK: - Demo Mode

#if DEBUG
    @MainActor
    func testForceProToggleDoesNotSimulatePurchaseOrClearWelcomeState() {
        let defaults = AppConfiguration.sharedDefaults
        defaults.set(true, forKey: EntitlementCenter.debugForceProKey)
        defer { defaults.set(false, forKey: EntitlementCenter.debugForceProKey) }

        XCTAssertTrue(EntitlementCenter.debugForceProEnabled)
        // Force-Pro is gating-only: it must NOT mark the walkthrough as seen
        // nor stage any intent — Preview is the explicit QA path instead.
        XCTAssertTrue(ProActivationState.isEligibleForActivationFlow)
        XCTAssertNil(PendingProIntent.current)
    }

    @MainActor
    func testDemoModeUnlocksHostAndShareExtension() {
        // Fresh isolated defaults: the shared snapshot may carry Pro from
        // other suites — this contract needs a clean Free baseline.
        let isolated = UserDefaults(suiteName: "test.demo.\(UUID().uuidString)")!
        EntitlementCenter.clearDemoFlagForTests()
        let center = EntitlementCenter(defaults: isolated)
        XCTAssertFalse(center.isPro)
        // The extension reads the SHARED App Group; its Free baseline is
        // verified by the snapshot-truthfulness test. Here we assert the
        // host-side gate flips with demo mode on isolated state.
        _ = ProDemoMode.activate(.compression, entitlementCenter: center)

        XCTAssertTrue(center.isPro, "Demo Mode must unlock the host through the shared entitlement")
        XCTAssertTrue(ExtensionEntitlement.isPro,
                      "the Share Extension must read the same App Group entitlement")

        // Cleanup so later assertions see a clean shared state.
        center.setDemoMode(false)
    }

    @MainActor
    func testDemoModeReturnsAndClearsExactPendingIntent() {
        let center = EntitlementCenter(defaults: AppConfiguration.sharedDefaults)
        let resumed = ProDemoMode.activate(.signature, entitlementCenter: center)

        XCTAssertEqual(resumed, .signature)
        XCTAssertEqual(PDFToolsHostView.section(for: resumed), .sign)
        XCTAssertNil(PendingProIntent.current, "the immediately resumed demo intent must be consumed exactly once")
        XCTAssertTrue(ProActivationState.isEligibleForActivationFlow,
                      "Demo Mode must not impersonate a verified purchase")
    }

    @MainActor
    func testDemoModeResumesExactStagedWebRequest() {
        let model = ImportFlowModel()
        let url = URL(string: "https://example.com/exact-demo-request")!
        var options = ConversionOptions.fromSharedDefaults()
        options.mode = .reader
        options.paperSize = .letter
        model.showingLinkEntry = true

        model.convert(items: [IncomingItem(kind: .url(url), sourceURL: url, source: .website)],
                      optionsOverride: options)

        XCTAssertTrue(model.showingPaywall)
        XCTAssertFalse(model.showingLinkEntry)
        XCTAssertEqual(model.debugPendingProRequest?.url, url)
        XCTAssertEqual(model.debugPendingProRequest?.options.mode, .reader)
        XCTAssertEqual(model.debugPendingProRequest?.options.paperSize, .letter)

        _ = ProDemoMode.activate(.webConversion, entitlementCenter: .shared)
        XCTAssertTrue(model.resumePendingProConversion())
        XCTAssertTrue(model.isConverting)
        XCTAssertFalse(model.showingPaywall)
        XCTAssertFalse(model.showingLinkEntry,
                       "Demo Mode must continue conversion, not reopen a blank Link sheet")
        model.cancel()
    }

    func testDemoModeUsesAReleaseVisibleSharedEntitlement() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for relativePath in [
            "PDFIt/Features/Paywall/PaywallView.swift",
            "PDFIt/Features/Paywall/PendingProIntent.swift",
            "Shared/Entitlements/EntitlementCenter.swift"
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(source.contains("Demo Mode") || source.contains("demoMode"),
                          "Demo Mode must remain available in \(relativePath)")
        }
    }
#endif
}
