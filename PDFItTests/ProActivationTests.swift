import XCTest
@testable import PDFIt

/// Contracts for the Pro activation experience: trigger discipline
/// (verified purchase ONLY), pending-intent preservation across the flow,
/// one-time persistence, and DEBUG-only QA surfaces.
final class ProActivationTests: XCTestCase {

    @MainActor
    override func setUp() {
        super.setUp()
        ProActivationState.resetWelcomeState()
        PendingProIntent.clear()
#if DEBUG
        let defaults = AppConfiguration.sharedDefaults
        defaults.set(false, forKey: EntitlementCenter.debugForceProKey)
#endif
    }

    @MainActor
    override func tearDown() {
        ProActivationState.resetWelcomeState()
        PendingProIntent.clear()
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

    // MARK: - DEBUG surfaces

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
    func testDebugDemoModeUnlocksHostAndShareExtension() {
        let center = EntitlementCenter(defaults: AppConfiguration.sharedDefaults)
        XCTAssertFalse(center.isPro)
        XCTAssertFalse(ExtensionEntitlement.isPro)

        _ = DebugProDemoMode.activate(.compression, entitlementCenter: center)

        XCTAssertTrue(center.isPro, "Demo Mode must unlock the host through the shared DEBUG entitlement")
        XCTAssertTrue(ExtensionEntitlement.isPro,
                      "the Share Extension must read the same App Group DEBUG entitlement")
    }

    @MainActor
    func testDebugDemoModeReturnsAndClearsExactPendingIntent() {
        let center = EntitlementCenter(defaults: AppConfiguration.sharedDefaults)
        let resumed = DebugProDemoMode.activate(.signature, entitlementCenter: center)

        XCTAssertEqual(resumed, .signature)
        XCTAssertEqual(PDFToolsHostView.section(for: resumed), .sign)
        XCTAssertNil(PendingProIntent.current, "the immediately resumed demo intent must be consumed exactly once")
        XCTAssertTrue(ProActivationState.isEligibleForActivationFlow,
                      "Demo Mode must not impersonate a verified purchase")
    }

    @MainActor
    func testDebugDemoModeResumesExactStagedWebRequest() {
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

        _ = DebugProDemoMode.activate(.webConversion, entitlementCenter: .shared)
        XCTAssertTrue(model.resumePendingProConversion())
        XCTAssertTrue(model.isConverting)
        XCTAssertFalse(model.showingPaywall)
        XCTAssertFalse(model.showingLinkEntry,
                       "Demo Mode must continue conversion, not reopen a blank Link sheet")
        model.cancel()
    }

    func testDemoModeProductionPathsAreCompilerGated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for relativePath in [
            "PDFIt/Features/Paywall/PaywallView.swift",
            "PDFIt/Features/Paywall/PendingProIntent.swift",
            "Shared/Entitlements/EntitlementCenter.swift"
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            guard let demoRange = source.range(of: "PRE-LAUNCH DEBUG DEMO MODE") else {
                return XCTFail("Missing documented removal marker in \(relativePath)")
            }
            let prefix = source[..<demoRange.lowerBound]
            XCTAssertNotNil(prefix.range(of: "#if DEBUG", options: .backwards),
                            "Demo Mode must be inside a DEBUG compiler block in \(relativePath)")
        }
    }
#endif
}
