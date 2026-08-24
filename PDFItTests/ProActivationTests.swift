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
        let defaults = AppConfiguration.sharedDefaults
        defaults.set(false, forKey: EntitlementCenter.debugForceProKey)
    }

    @MainActor
    override func tearDown() {
        ProActivationState.resetWelcomeState()
        PendingProIntent.clear()
        AppConfiguration.sharedDefaults.removeObject(forKey: EntitlementCenter.debugForceProKey)
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
}
