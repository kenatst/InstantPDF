import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Home: premium branded header, hero with the mascot breaking the card
/// boundary, four mascot source cards, recent work. No giant app-name
/// navigation title — the brand lockup IS the header.
struct HomeView: View {
    @Binding var showingSettings: Bool

    @StateObject private var importer = ImportFlowModel()
    @StateObject private var scanModel = ScanFlowModel()
    @State private var records: [StoredPDFRecord] = []
    /// Hero tap opens the polished source chooser instead of guessing.
    @State private var showingSourceChooser = false
    @State private var showingScanner = false
    /// Post-scan persistence failure count (user-facing alert).
    @State private var scanSaveFailureCount = 0
    /// Typed viewer routing: the exact created/tapped document ID.
    @State private var presentedViewerID: UUID?
    /// One-time Pro offer right after onboarding (Free stays fully usable).
    @AppStorage(AppSettingsKeys.hasPresentedInitialProOffer)
    private var hasPresentedInitialProOffer = false
    @State private var showingOnboardingPaywall = false
    /// Post-purchase celebration + tutorial + feature guide.
    @State private var showingProActivation = false

    private let storage = StorageManager.shared
    @ObservedObject private var entitlements = EntitlementCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xxl) {
                brandHeader
                    .padding(.top, Theme.Spacing.xs)

                heroCard

                scanCard

                actionGrid

                recentSection
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, 40)
        }
        .themeBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { reloadRecords() }
        .onChange(of: scenePhase, initial: false) { _, newPhase in
            if newPhase == .active { reloadRecords() }
        }
        .onChange(of: importer.photoSelections, initial: false) { _, _ in
            importer.handlePhotoSelections()
        }
        .sheet(isPresented: $showingScanner) {
            ScanFlowSheet(model: scanModel) { documents in
                // REAL persistence: every document must be saved or the user
                // hears about it. No silent `try?`. The scan sheet keeps its
                // generated PDFs alive until each save is acknowledged, so a
                // failed write is retryable instead of silently destroyed.
                var failures = 0
                var lastSavedID: UUID?
                for document in documents {
                    do {
                        let record = try storage.save(document: document)
                        lastSavedID = record.id
                    } catch {
                        failures += 1
                    }
                }
                if failures > 0 {
                    scanSaveFailureCount = failures
                }
                reloadRecords()
                if let id = lastSavedID {
                    // Open the exact created document.
                    showingScanner = false
                    presentedViewerID = id
                }
            }
            .interactiveDismissDisabled(scanModel.isConvertingForUI)
        }
        .navigationDestination(item: $presentedViewerID) { id in
            PDFViewerView(recordID: id)
        }
        .alert("Couldn't save scan", isPresented: Binding(get: { scanSaveFailureCount > 0 },
                                                          set: { if !$0 { scanSaveFailureCount = 0 } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scanSaveFailureCount == 1
                 ? "The scanned PDF couldn't be saved to your Library. Your pages are kept — try again."
                 : "\(scanSaveFailureCount) documents couldn't be saved to your Library. Your pages are kept — try again.")
        }
        .sheet(isPresented: $showingOnboardingPaywall) {
            PaywallView(feature: .webConversion,
                        showsContinueFree: true,
                        onVerifiedPurchase: { _ in
                // Verified purchase from the onboarding paywall: celebrate,
                // teach, then land on Home. No pending intent to resume —
                // the flow's finish clears it anyway.
                showingProActivation = true
            })
        }
        .sheet(isPresented: $showingProActivation) {
            ProActivationFlow { intent in
                handleProActivationCompletion(intent)
            }
        }
        .onAppear {
            if !hasPresentedInitialProOffer {
                hasPresentedInitialProOffer = true
                if !EntitlementCenter.shared.isPro {
                    showingOnboardingPaywall = true
                }
            }
        }
        .sheet(isPresented: $importer.showingPaywall) {
#if DEBUG
            PaywallView(feature: importer.requiresPro ?? .webConversion,
                        onVerifiedPurchase: { feature in
                // Contextual purchase (Link, etc.): run the activation flow,
                // then RESUME the exact action that was requested.
                showingProActivation = true
            }, onDebugDemoMode: { intent in
                // Demo Mode is not a purchase: resume immediately without
                // celebration or changing real purchase state.
                handleProActivationCompletion(intent)
            })
#else
            PaywallView(feature: importer.requiresPro ?? .webConversion) { _ in
                showingProActivation = true
            }
#endif
        }
        .fileImporter(isPresented: $importer.showingFileImporter,
                      allowedContentTypes: [.image, .pdf, .text, .plainText, .html, .rtf],
                      allowsMultipleSelection: true) { result in
            importer.handleFileImporter(result: result)
        }
        .sheet(isPresented: $showingSourceChooser) {
            SourceChooserSheet { source in
                showingSourceChooser = false
                switch source {
                case .photos: importer.showingPhotoPicker = true
                case .link: importer.showingLinkEntry = true
                case .text: importer.showingTextEntry = true
                case .files: importer.showingFileImporter = true
                }
            }
        }
        .sheet(isPresented: $importer.showingPhotoPicker) {
            PhotosPickerSheet(selection: $importer.photoSelections)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $importer.showingResult) {
            if let result = importer.result {
                ConversionResultSheet(document: result)
            }
        }
        .sheet(isPresented: $importer.showingError) {
            if let error = importer.failure {
                ConversionErrorSheet(error: error,
                                     onRetry: { importer.retry() },
                                     offerLinkAsPDF: false,
                                     onSaveLinkAsPDF: nil)
            }
        }
        .sheet(isPresented: $importer.showingCustomize) {
            CustomizePDFSheet(customization: $importer.customization,
                              imageOrder: importer.pendingImageOrder.count > 1
                                ? Binding(get: { importer.pendingImageOrder },
                                          set: { importer.pendingImageOrder = $0 })
                                : nil,
                              onCreateStaged: importer.stagedWebConversion != nil
                                ? { importer.convertStagedWebConversion() }
                                : nil)
        }
        .sheet(isPresented: $importer.showingLinkEntry) {
            LinkEntrySheet { url, mode, paperSize in
                var options = ConversionOptions.fromSharedDefaults()
                options.mode = mode
                options.paperSize = paperSize
                importer.convert(items: [IncomingItem(kind: .url(url),
                                                      sourceURL: url,
                                                      source: ContentSource.detect(from: url))],
                                 optionsOverride: options)
            } onCustomize: { url, mode, paperSize in
                // Carry EVERYTHING forward: URL + mode + paper survive the
                // Customize transition and are used at creation time.
                importer.stageWebConversion(url: url,
                                            mode: mode,
                                            paperSize: paperSize)
                importer.showingLinkEntry = false
                importer.showingCustomize = true
            }
        }
        .sheet(isPresented: $importer.showingTextEntry) {
            TextEntrySheet { text, title in
                importer.convert(items: [IncomingItem(kind: .text(text),
                                                      title: title,
                                                      source: .textEditor)])
            }
        }
    }

    // MARK: - Compact brand lockup (replaces the giant nav title).
    // Settings lives HERE — a real 44pt button in the visible header —
    // because the navigation bar is hidden on Home and a toolbar-based
    // gear was unreachable on device.

    private var brandHeader: some View {
        ZStack {
            Text("PDFIT")
                .font(.system(size: 23, weight: .black, design: .rounded))
                .kerning(1.2)
                .foregroundStyle(colorScheme == .dark ? .white : Theme.Colors.ink)
                .accessibilityLabel("PDF It")

            HStack {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.9) : Theme.Colors.ink)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Theme.Colors.surface)
                                .overlay(
                                    Circle().strokeBorder(
                                        colorScheme == .dark ? Theme.Colors.darkStroke : Theme.Colors.stroke.opacity(0.75),
                                        lineWidth: 1
                                    )
                                )
                                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 10, y: 4)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home_settings_gear")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    // MARK: - Scan hero (primary Free action)

    private var scanCard: some View {
        Button {
            // THE entry point: opens the scanner flow. The camera sheet is
            // presented INSIDE ScanReviewView (bound to model.showingCamera);
            // this outer sheet shows the review UI around it.
            showingScanner = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                MascotView(type: .scan, size: 78, enableFloatingAnimation: false)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Scan Document")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(colorScheme == .dark ? .white : Theme.Colors.ink)
                    Text("Turn paper documents into clean, readable PDFs.")
                        .font(.footnote)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.62) : Theme.Colors.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.feature, style: .continuous)
                    .fill(colorScheme == .dark ? Theme.Colors.darkCard : Theme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.feature, style: .continuous)
                            .strokeBorder(colorScheme == .dark ? Theme.Colors.darkStroke : Theme.Colors.stroke.opacity(0.75), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.065), radius: 14, y: 7)
            )
        }
        .buttonStyle(.plain)
        .disabled(!ScanCameraView.isSupported)
        .accessibilityLabel("Scan Document")
    }

    // MARK: - Hero card with mascot escaping the boundary

    private var heroCard: some View {
        Button {
            showingSourceChooser = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Anything → PDF")
                            .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 30 : 32,
                                          weight: .heavy,
                                          design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Photos, webpages, text and files.\nOne PDF. In seconds.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 7) {
                            Text("Create PDF")
                                .font(.subheadline.weight(.bold))
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.black))
                        }
                        .foregroundStyle(Color(hex: "7A2E00"))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 40)
                        .background(Color.white, in: Capsule())
                        .shadow(color: Theme.Colors.orangeDark.opacity(0.2), radius: 8, y: 4)
                        .padding(.top, Theme.Spacing.xs)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Spacing.xl)
                    .padding(.leading, Theme.Spacing.xl)
                    .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? Theme.Spacing.xl : 124)
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                        .fill(Theme.Colors.heroCardGradient)
                        .overlay(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        }
                        .shadow(color: Theme.Colors.orangeDark.opacity(0.24), radius: 18, x: 0, y: 10)
                )

                if !dynamicTypeSize.isAccessibilitySize {
                    MascotView(type: .hero, size: 155, enableFloatingAnimation: true)
                        .offset(x: 14, y: 18)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create PDF")
        .accessibilityHint("Choose photos, a link, text or files")
    }

    // MARK: - 4 mascot source cards

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible(), spacing: Theme.Spacing.sm)], spacing: Theme.Spacing.sm) {
            PhotosPicker(selection: $importer.photoSelections, matching: .images) {
                MascotActionCard(category: .photos)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import photos")

            Button {
                importer.showingLinkEntry = true
            } label: {
                MascotActionCard(category: .link)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if !EntitlementCenter.shared.isPro {
                    ProBadge()
                        .padding(8)
                }
            }

            Button {
                importer.showingTextEntry = true
            } label: {
                MascotActionCard(category: .text)
            }
            .buttonStyle(.plain)

            Button {
                importer.showingFileImporter = true
            } label: {
                MascotActionCard(category: .files)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recent section

    @ViewBuilder
    private var recentSection: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Recent")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(colorScheme == .dark ? .white : Theme.Colors.ink)
                    Spacer()
                    NavigationLink(value: LibraryRoute.library) {
                        Text("See All")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                    }
                }
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

                VStack(spacing: 8) {
                    ForEach(records.prefix(5)) { record in
                        Button {
                            presentedViewerID = record.id
                        } label: {
                            RecentPDFRow(record: record)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .library:
                    LibraryView(embedded: true)
                case .viewer(let recordID):
                    PDFViewerView(recordID: recordID)
                }
            }
        }
    }

    private func reloadRecords() {
        records = storage.fetchRecords()
    }

    /// Called when the activation flow finishes. If the purchase originated
    /// from a concrete action (Sign/Compress/OCR/Link…), resume it now.
    @MainActor
    private func handleProActivationCompletion(_ intent: ProFeature?) {
        switch intent {
        case .linkConversion, .webConversion:
            if !importer.resumePendingProConversion() {
                // Defensive fallback for an activation started somewhere
                // other than Link entry: reopen the correct surface.
                importer.requiresPro = nil
                importer.showingLinkEntry = true
            }
        default:
            // Viewer-context intents (Sign/Compress/OCR/Extract) resume
            // inside PDFToolsHostView, which owns its own activation flow.
            break
        }
    }

    // MARK: - Home intentionally hides the system navigation bar: the custom
    // brand header above IS the product header (brand + Settings gear).
    // Nothing else lives in toolbar content.
}

/// Navigation routes shared by Home and Library. Viewer routes carry the
/// persistent record ID — the destination re-resolves fresh state from
/// storage, so rename/move can never desynchronize identity.
enum LibraryRoute: Hashable {
    case library
    case viewer(recordID: UUID)
}

// MARK: - Restrained Pro badge

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Theme.Colors.orangeGradient)
            )
            .accessibilityLabel("Pro feature")
    }
}

// MARK: - Source chooser (hero CTA target)

enum ImportSource: String, CaseIterable, Identifiable {
    case photos, link, text, files
    var id: String { rawValue }
}

struct SourceChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let onChoose: (ImportSource) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 20) {
            MascotView(type: .hero, size: 84, enableFloatingAnimation: false)
            VStack(spacing: 4) {
                Text("What are we turning into a PDF?")
                    .font(.headline.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Pick a source to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ImportSource.allCases) { source in
                    Button {
                        onChoose(source)
                    } label: {
                        MascotActionCard(category: MascotActionCard.Category(rawValue: source.rawValue) ?? .photos)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if source == .link && !EntitlementCenter.shared.isPro {
                            ProBadge()
                                .padding(Theme.Spacing.xs)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .themeBackground()
        .presentationDetents([.large])
    }
}

/// Photos picker as its own sheet so both the card and the chooser can open it.
struct PhotosPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: [PhotosPickerItem]

    var body: some View {
        NavigationStack {
            VStack {
                PhotosPicker(selection: $selection,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                }
                .primaryOrangeButton()
                .padding(20)
                Spacer()
            }
            .themeBackground()
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Mascot source card

struct MascotActionCard: View {
    enum Category: String {
        case photos, link, text, files

        var mascotType: MascotView.MascotType {
            switch self {
            case .photos: return .photos
            case .link: return .link
            case .text: return .text
            case .files: return .files
            }
        }
    }

    let category: Category
    @Environment(\.colorScheme) private var colorScheme

    private var title: LocalizedStringKey {
        switch category {
        case .photos: return "Photos"
        case .link: return "Link"
        case .text: return "Text"
        case .files: return "Files"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch category {
        case .photos: return "From your photo library"
        case .link: return "From a URL"
        case .text: return "Write or paste"
        case .files: return "From your device"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            MascotView(type: category.mascotType, size: 108, enableFloatingAnimation: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(colorScheme == .dark ? .white : Theme.Colors.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.58) : Theme.Colors.inkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.xxs)
                categoryBadge
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Theme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Theme.Colors.darkStroke : Theme.Colors.stroke.opacity(0.65), lineWidth: 1)
                )
                .shadow(color: colorScheme == .dark ? Color.black.opacity(0.24) : Color(hex: "6F4D35").opacity(0.07), radius: 12, x: 0, y: 6)
        )
    }

    /// The category glyph sits in a warm tile next to the mascot — one
    /// consistent composition across all four cards.
    private var categoryBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.Colors.orangePrimary.opacity(0.16))
                .frame(width: 32, height: 32)
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.orangePrimary)
        }
    }

    private var symbolName: String {
        switch category {
        case .photos: return "photo.on.rectangle.angled"
        case .link: return "link"
        case .text: return "doc.text"
        case .files: return "folder"
        }
    }
}

// MARK: - Recent PDF Row Component

private struct RecentPDFRow: View {
    let record: StoredPDFRecord
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            if let image = StorageManager.shared.thumbnailImage(for: record) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Colors.orangePrimary.opacity(0.12))
                        .frame(width: 44, height: 56)
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Text("•")
                    Text(String(localized: "plural.pages \(record.pageCount)", bundle: LanguageManager.bundle))
                    Text("•")
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                }
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04), lineWidth: 1)
                )
        )
    }
}
