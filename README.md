# PDF It

**Anything → PDF. Share it. PDF it. Done.**

PDF It is a local-first iOS utility that turns anything you share — photos, webpages, text, files, even existing PDFs — into a clean PDF in seconds. No account, no cloud processing, no clutter.

---

## Overview

- **Share-first**: the product lives in the Share Extension. Share from Photos, Safari, Notes, Mail, Files or any app that exposes images, URLs, text or documents, and PDF It takes it from there.
- **Local-first**: every conversion happens on the device whenever possible. Nothing is uploaded. No analytics, ads or trackers.
- **Never destructive**: sharing an existing PDF passes the original bytes through untouched in Quick mode — no watermarks, no footers, no page re-imposition.
- **Keeps your documents**: generated PDFs are stored in your Library until *you* delete them. There is no silent history pruning.

## Repository layout

```
PDFIt.xcodeproj          Committed project — clone, open, build
PDFIt/                   Main app (SwiftUI): Home, Import, Library, Viewer, Settings, Onboarding
Shared/                  Core compiled into BOTH the app and the Share Extension
    Models/              IncomingItem, ConversionOptions, ContentSource
    Input/               InputProcessor (NSItemProvider), InputClassification
    Conversion/          ConversionCoordinator + image/text/existing-PDF converters
    PDF/                 PDFAssembly (merge, slicing, passthrough), AspectLayout, paper sizes
    Web/                 WebPDFConverter (WKWebView), WebContentExtractor (Clean/Reader)
    Storage/             StorageManager + StoredPDFRecord (library persistence)
    Utilities/           FilenameGenerator, TempFileStore, AppConfiguration
ShareExtension/          The Share Extension UI (UIKit, state-machine driven)
PDFItTests/              Unit tests
Config/                  Info.plists + entitlements for both targets
```

Both targets compile the same `Shared/` engine — there is exactly one conversion path, used by the Share Extension and the in-app import alike.

## Targets

| Target | Bundle ID | Type |
|---|---|---|
| PDF It | `com.kenatst.pdfit` | Main application |
| PDF It Share | `com.kenatst.pdfit.share` | Share Extension |
| PDFItTests | `com.kenatst.pdfit.tests` | Unit test bundle |

Both the app and the extension carry the App Group entitlement `group.com.kenatst.pdfit` (see `Config/*.entitlements`), used for the shared document Library and shared preferences. The identifier is defined once in `Shared/AppConfiguration.swift`.

## Localization

PDF It ships with full native localization in **5 locales** via Apple String Catalogs (`Localizable.xcstrings`):

* 🇺🇸 **English** (`en`) — Primary Development Language
* 🇫🇷 **French** (`fr`)
* 🇪🇸 **Spanish** (`es`)
* 🇩🇪 **German** (`de`)
* 🇮🇹 **Italian** (`it`)

All user-facing strings, plurals (pages, items, files, images, skipped media notices), formatting (locale-aware dates and byte counts), error headlines, and recovery actions are fully localized.

## Privacy & App Store Compliance

* **Privacy Manifest**: `Config/PrivacyInfo.xcprivacy` declares all Required Reason APIs (`NSPrivacyAccessedAPICategoryUserDefaults`, `NSPrivacyAccessedAPICategoryFileTimestamp`, `NSPrivacyAccessedAPICategoryDiskSpace`) with `NSPrivacyTracking: false` and zero data collection.
* **App Store Documentation**:
  * `APP_STORE_METADATA.md` — Multi-language store listings for EN, FR, ES, DE, IT with validated character and byte constraints.
  * `APP_STORE_PRIVACY.md` — App Store Connect questionnaire answers and local-processing disclosures.
  * `APP_REVIEW_NOTES.md` — Step-by-step test guide for Apple App Review.
* **External Links**: Centralized in `Shared/AppConfiguration.swift` (`privacyPolicy`, `termsOfUse`, `support`).

## Building

```bash
git clone https://github.com/kenatst/InstantPDF.git
cd InstantPDF
open PDFIt.xcodeproj     # Xcode does the rest
```

Command line:

```bash
xcodebuild build -project PDFIt.xcodeproj -scheme PDFIt \
  -destination 'platform=iOS Simulator,name=iPhone 16e'

xcodebuild test -project PDFIt.xcodeproj -scheme PDFIt \
  -destination 'platform=iOS Simulator,name=iPhone 16e'
```

- No CocoaPods / SPM / Tuist dependencies.
- The simulator build needs no signing team. For device builds, set your Development Team; update the App Group in `AppConfiguration.swift` and both `Config/*.entitlements` to a prefix you control, and change the bundle IDs accordingly.

## Supported inputs

| Input | Behavior |
|---|---|
| Images (JPEG/PNG/HEIC/AVIF) | One image per page, order preserved, EXIF orientation honored, ImageIO downsampling |
| Multiple images | Merged multi-page PDF in Share Sheet order |
| Plain text / RTF | Paginated, typographically set Core Text PDF |
| Web URLs | Loaded in an offscreen WKWebView and captured as vector PDF |
| HTML handed over by apps | Rendered and paginated locally |
| Existing PDFs | **Byte-perfect passthrough** (Quick, single PDF) or lossless page merge |
| Generic files | Attached as a titled cover page; text-like files become readable PDFs |
| Video / audio | Not supported (rejected up front) |

Files over 100 MB are rejected to protect the extension's memory budget.

## Conversion modes

- **Quick** — faithful to the source. Images keep their aspect; webpages are captured as loaded; existing PDFs are untouched.
- **Clean** — webpages only: DOM-based reader extraction strips nav/ads/footers/cookie bars, then renders a polished document. Low extraction confidence falls back to Quick automatically.
- **Reader** — the same extraction pipeline with an editorial serif layout.

Page size is selectable per conversion (Auto / A4 / US Letter). Tall web captures are sliced into real printable pages — no 20,000-point PDFs.

## Conversion pipeline

```
Share sheet / Import
   ↓ InputProcessor (NSItemProvider → staged temp files, ordering preserved)
   ↓ ConversionCoordinator (one converter per item, cancellation-checked)
   ↓ [ImagePDFConverter | TextPDFConverter | ExistingPDFConverter | WebPDFConverter]
   ↓ PDFAssembly (merge + metadata: title, creator "PDF It", source URL)
   ↓ StorageManager (atomic write, collision-safe filename, thumbnail, library record)
   ↓ Preview → Share / Save / Print
```

Failures are surfaced as human error states ("We couldn't load this page", with Retry / Save Link as PDF / Cancel) — never as text baked into a PDF.

## Filenames

Human names, not timestamps: `Paris Trip — 22 Aug 2026.pdf`, `Thread — username.pdf`, `5 Photos.pdf`. Slashes/control characters are sanitized, names are capped at 80 characters, and collisions get a ` 2`, ` 3` suffix instead of overwriting.

## Testing

Over 110 automated tests cover input classification, attachment ordering, source detection, paper sizes, aspect fit/fill math, filename sanitization and collisions, text pagination (including empty-input safety), image pagination, existing-PDF byte preservation and page-box preservation, merge order, web-capture slicing, metadata stamping, storage contracts, and comprehensive localization / privacy manifest verification.

- **Share flow (`ShareFlowModel`)** — synthetic `NSExtensionItem` + `NSItemProvider` harness drives the real chain `NSItemProvider → InputProcessor → Ready state → ConversionCoordinator → StorageManager`.
- **Cross-process App Group persistence** — two independent `StorageManager` instances over one container verify the app and the extension see each other's saves/deletes without loss.
- **WKWebView pipeline & cancellation** — offline HTML captures exercise the navigation/stabilization/evaluation/render continuations directly.
- **Localization & Privacy (`LocalizationAndProductTests`)** — validates `PrivacyInfo.xcprivacy` schema, `Localizable.xcstrings` JSON and 5-locale completeness, pluralization rules, and external links.

```bash
xcodebuild test -project PDFIt.xcodeproj -scheme PDFIt \
  -destination 'platform=iOS Simulator,name=iPhone 16e'
```

## Known limitations

- Clean/Reader extraction is heuristic DOM analysis; some sites yield little extractable text and fall back to a Quick capture. That is by design — a fallback beats a mangled document.
- X/Twitter links get the standard web pipeline plus `Thread — username` naming. No authentication bypass, no private APIs, no thread scraping.
- The extension only sees what the source app exposes through the share sheet; PDF It cannot reach entire conversations in Mail or Messages.
- App Groups on device require a matching provisioning profile; the simulator works without one.

## Privacy

Conversions run on device whenever possible. No account, no analytics SDK, no advertising SDK, no content-upload backend, no trackers. The only network traffic is the webpage you explicitly ask to convert.
