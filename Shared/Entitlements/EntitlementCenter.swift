import Foundation
import StoreKit

/// Centralized StoreKit 2 entitlement authority. Backend-free by design:
/// the App Store is the only source of truth, verified locally.
///
/// The Share Extension NEVER touches StoreKit. This center publishes a
/// minimal JSON snapshot of the entitlement state into the App Group after
/// every recompute and at app launch; the extension reads that snapshot to
/// gate itself (Pro → normal conversion, Free → informational state).
@MainActor
final class EntitlementCenter: ObservableObject {

    static let shared = EntitlementCenter()

    enum Status: Equatable {
        case idle
        case loading
        case entitled
        case notEntitled
        /// Purchase awaiting external action (Ask to Buy / SCA).
        case pending
        /// StoreKit unreachable or failed — treated as Free, never crashes.
        case unavailable(String)

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    nonisolated static let productIDs = [
        "com.kenatst.pdfit.pro.monthly",
        "com.kenatst.pdfit.pro.annual",
        "com.kenatst.pdfit.pro.lifetime",
    ]
    nonisolated static let snapshotKey = "entitlement.snapshot"
#if DEBUG
    /// DEBUG-ONLY developer override ("Settings → Developer → Force PDF It Pro").
    /// Stored in the APP GROUP so the Share Extension honors it too, letting the
    /// tester exercise Pro flows before App Store Connect products exist.
    /// The Release compile of this property is hardcoded `false` — no user
    /// default can ever unlock Pro in production.
    nonisolated static let debugForceProKey = "debug.forcePro"

    nonisolated static var debugForceProEnabled: Bool {
        return UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)?
            .bool(forKey: debugForceProKey) ?? false
    }

    /// PRE-LAUNCH DEBUG DEMO MODE
    /// Remove this method and the Paywall action before App Store production.
    /// The flag is stored directly in the shared App Group defaults: the host
    /// and Share Extension therefore read one authoritative debug override.
    func setDebugProOverride(_ enabled: Bool) {
        UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)?
            .set(enabled, forKey: Self.debugForceProKey)
        objectWillChange.send()
    }
#endif

    /// Effective Pro state. The stored verdict comes from StoreKit
    /// recomputation; in DEBUG builds the developer force-Pro toggle is OR-ed
    /// at read time (never persisted into the extension-facing snapshot).
    @Published private(set) var _storePro: Bool = false
    var isPro: Bool {
#if DEBUG
        return _storePro || Self.debugForceProEnabled
#else
        return _storePro
#endif
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var products: [Product] = []
    @Published private(set) var expiresAt: Date?

    /// Expiration instant carried in the last published snapshot (if any).
    private(set) var snapshotExpiration: Date?

    private let defaults: UserDefaults
    private var updatesTask: Task<Void, Never>?
    private var productsTask: Task<Void, Never>?
    private var started = false

    init(defaults: UserDefaults = AppConfiguration.sharedDefaults) {
        self.defaults = defaults
        // Adopt the last known state immediately so cold launch shows the
        // previous verdict before StoreKit answers.
        if let stored = Self.decodeSnapshot(defaults.string(forKey: Self.snapshotKey)) {
            _storePro = stored.pro
            snapshotExpiration = stored.expires
        }
    }

    deinit {
        updatesTask?.cancel()
        productsTask?.cancel()
    }

    /// Idempotent startup: begins transaction listening + product load +
    /// initial recompute. Called once from the app root on launch.
    func start() {
        guard !started else { return }
        started = true
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                // Dismiss unverified updates; verified ones retrigger recompute
                // through the same path as foreground purchases.
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self?.recompute()
                }
            }
        }
        Task { [weak self] in
            await self?.recompute()
        }
        loadProducts()
    }

    // MARK: - Recompute

    /// Rebuilds Pro state from `Transaction.currentEntitlements`. Verified,
    /// active monthly/annual/lifetime → Pro; everything else drops out.
    func recompute() async {
        var pro = false
        var expiration: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard Self.productIDs.contains(transaction.productID) else { continue }
            seenProductIDs.insert(transaction.productID)
            pro = true
            if let exp = transaction.expirationDate {
                expiration = max(expiration ?? .distantPast, exp)
            }
        }
        _storePro = pro
        expiresAt = expiration
        status = pro ? .entitled : .notEntitled
        publishSnapshot()
        lastSeenProductIDs = seenProductIDs
    }

    private var seenProductIDs: Set<String> = []
    @Published private(set) var lastSeenProductIDs: Set<String> = []

    // MARK: - Purchase / restore

    enum PurchaseOutcome: Equatable {
        case success
        case userCancelled
        case pending
        case failed(String)
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await recompute()
                    return .success
                }
                return .failed("Unverified transaction")
            case .userCancelled:
                return .userCancelled
            case .pending:
                status = .pending
                return .pending
            @unknown default:
                return .failed("Unknown purchase result")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// AppStore.sync() prompts the system restore sheet, then we recompute.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            // Restore sheet cancelled or offline — recompute anyway so a
            // previously-verified entitlement isn't lost from the UI.
        }
        await recompute()
    }

    // MARK: - Products

    private func loadProducts() {
        productsTask?.cancel()
        productsTask = Task { [weak self] in
            // Bounded retry policy. An empty product list (App Store Connect
            // products not yet created) is TERMINAL, not a transient error —
            // the UI must show "unavailable", never an endless spinner.
            var attempt = 0
            let maxAttempts = 3
            while !Task.isCancelled {
                do {
                    let loaded = try await Product.products(for: Self.productIDs)
                    guard let self else { return }
                    if loaded.isEmpty && attempt < maxAttempts - 1 {
                        attempt += 1
                        self.status = .loading
                        let seconds = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        try? await Task.sleep(nanoseconds: seconds)
                        continue
                    }
                    self.products = Self.sorted(loaded)
                    if self.status == .loading || self.status == .idle || self.status.isUnavailable {
                        self.status = self.isPro ? .entitled : .notEntitled
                    }
                    return
                } catch {
                    attempt += 1
                    guard let self else { return }
                    if attempt >= maxAttempts {
                        self.status = .unavailable(error.localizedDescription)
                        return
                    }
                    self.status = .unavailable(error.localizedDescription)
                    // Backoff: 2s, 4s… capped. No retry storm.
                    let seconds = min(8, UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: seconds)
                }
            }
        }
    }

    /// Manual re-fetch (paywall Retry button).
    func refreshProducts() {
        loadProducts()
    }

    private static func sorted(_ products: [Product]) -> [Product] {
        products.sorted { lhs, rhs in
            let order = [Self.productIDs[0], Self.productIDs[1], Self.productIDs[2]]
            return (order.firstIndex(of: lhs.id) ?? 99) < (order.firstIndex(of: rhs.id) ?? 99)
        }
    }

    var monthlyProduct: Product? { products.first { $0.id == Self.productIDs[0] } }
    var annualProduct: Product? { products.first { $0.id == Self.productIDs[1] } }
    var lifetimeProduct: Product? { products.first { $0.id == Self.productIDs[2] } }

    // MARK: - App Group snapshot (extension-facing)

    struct Snapshot: Codable, Equatable {
        let pro: Bool
        let expires: Date?
        let updated: Date
    }

    private func publishSnapshot() {
        // The snapshot reflects the REAL StoreKit verdict only — the DEBUG
        // force-Pro override is a host/dev-side convenience and must never be
        // persisted as an entitlement.
        let snapshot = Snapshot(pro: _storePro,
                                expires: expiresAt,
                                updated: Date())
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.snapshotKey)
    }

    /// Decodes a snapshot string. Static + internal for unit tests.
    nonisolated static func decodeSnapshot(_ json: String?) -> Snapshot? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Reads the CURRENT published snapshot — the extension's single source
    /// of entitlement truth. Static so it can be called without MainActor.
    nonisolated static func currentSnapshot(fromDefaults defaults: UserDefaults) -> Snapshot? {
        decodeSnapshot(defaults.string(forKey: Self.snapshotKey))
    }
}

extension EntitlementCenter: EntitlementReading {}

/// Extension-side entitlement view: reads ONLY the App Group snapshot.
/// In DEBUG builds the developer force-Pro toggle (host app → Settings →
/// Developer) is honored so the tester can exercise Pro conversion before
/// App Store Connect products exist. Release builds ignore it entirely.
enum ExtensionEntitlement {
    static var isPro: Bool {
#if DEBUG
        if EntitlementCenter.debugForceProEnabled { return true }
#endif
        guard let defaults = UserDefaults(suiteName: AppConfiguration.appGroupIdentifier),
              let snapshot = EntitlementCenter.currentSnapshot(fromDefaults: defaults) else {
            return false
        }
        guard snapshot.pro else { return false }
        if let expires = snapshot.expires, expires < Date() {
            return false
        }
        return true
    }
}
