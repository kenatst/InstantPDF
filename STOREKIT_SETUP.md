# StoreKit Setup — PDF It Pro

Two independent things must NOT be confused:

1. **Local testing** (`Config/PDFIt.storekit`) — works TODAY on any Mac, no App
   Store Connect access needed.
2. **Production setup** (App Store Connect) — required before TestFlight/App
   Store review. Owner action only.

---

## A. Local testing with the `.storekit` configuration

`Config/PDFIt.storekit` defines all three products with representative local
test prices:

| Product ID | Type | Local test price |
|---|---|---|
| `com.kenatst.pdfit.pro.monthly` | Auto-renewable subscription | $1.99 / month |
| `com.kenatst.pdfit.pro.annual` | Auto-renewable subscription | $14.99 / year |
| `com.kenatst.pdfit.pro.lifetime` | Non-consumable | $24.99 |

To activate it in Xcode:

1. **Product → Scheme → Edit Scheme…**
2. Select **Run**
3. Open the **Options** tab
4. Set **StoreKit Configuration** → `Config/PDFIt.storekit`
5. Run the app; purchases now hit the local store.
   - Transactions appear in the transaction manager (debug toolbar icon).
   - Subscriptions can be fast-forwarded/refunded locally to test expiry and
     revocation behavior.

Prices in this file NEVER ship to users — production pricing comes exclusively
from App Store Connect. The paywall UI renders whatever StoreKit returns and
hardcodes nothing.

---

## B. Production setup (App Store Connect) — owner checklist

Prerequisite: Agreements, Tax & Banking accepted for paid apps.

1. Sign in to **appstoreconnect.apple.com** → My Apps → **PDF It**
2. Go to **Monetization → In-App Purchases / Subscriptions**
3. Create a **Subscription Group** named `PDF It Pro`
4. Inside that group create two auto-renewable subscriptions:
   - `com.kenatst.pdfit.pro.monthly` — duration **1 month**
   - `com.kenatst.pdfit.pro.annual` — duration **1 year**
   - For each: display name, description, localized metadata (EN + FR + ES +
     DE + IT), review screenshot, and price tier.
5. Create a **Non-Consumable In-App Purchase**:
   - `com.kenatst.pdfit.pro.lifetime`
   - Same localization/review requirements as above.
6. Attach both subscriptions and the non-consumable to the app version.
7. Verify **Paid Apps Agreement** status = Active (purchases return empty
   products otherwise — the app shows "temporarily unavailable", never a
   spinner).
8. Submit for review together with the binary.

### Sandbox / TestFlight testing

- Create Sandbox Tester accounts (Users and Access → Sandbox → Testers).
- On device signed into a sandbox account, purchases follow the accelerated
  renewal schedule (1 month ≈ 5 minutes) which is ideal for expiry testing.
- TestFlight builds use real products once step 4–6 are live.

---

## C. Debug force-Pro (development convenience ONLY)

`Settings → Developer → Force PDF It Pro` exists **only in DEBUG builds**.
It flips gating in the host app AND the Share Extension through an App Group
flag so the tester can exercise Pro flows before ASC products exist.

Guarantees:
- The flag is compiled out of Release (`EntitlementCenter.debugForceProEnabled`
  returns hardcoded `false` outside DEBUG); no user default can unlock Pro.
- The App Group entitlement snapshot always reflects the REAL StoreKit verdict;
  force-Pro is read-time-only in the host and can never persist "Pro" into
  extension state.
