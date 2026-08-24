import SwiftUI
import PDFKit

/// The PDF grid card: real thumbnail, title, source badge, pages, size, date.
/// `showBadge` is disabled in selection mode (the checkmark replaces it).
struct LibraryGridCard: View {
    let record: StoredPDFRecord
    var showBadge: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // PDF Preview thumbnail.
            // Hit-test safety contract: the image is an OVERLAY on a sized,
            // clipped container — it can never extend past the card bounds
            // and never intercepts touches (purely visual).
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Theme.Colors.surfaceMuted)

                if let image = StorageManager.shared.thumbnailImage(for: record) {
                    Color.clear
                        .overlay(
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(9)
                        )
                        .frame(maxWidth: .infinity, maxHeight: 164)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Colors.orangePrimary.opacity(0.8))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 164)
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                if showBadge {
                    Image(systemName: record.contentSource.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : Theme.Colors.ink)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Label {
                        Text(String(localized: "plural.pages \(record.pageCount)", bundle: LanguageManager.bundle))
                    } icon: {
                        Image(systemName: record.contentSource.symbolName)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                }
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.58) : Theme.Colors.inkSecondary)

                Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.48) : Theme.Colors.inkSecondary)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Theme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Theme.Colors.darkStroke : Theme.Colors.stroke.opacity(0.72), lineWidth: 1)
                )
                .shadow(color: colorScheme == .dark ? Color.black.opacity(0.24) : Color(hex: "6F4D35").opacity(0.07), radius: 12, x: 0, y: 6)
        )
    }
}

/// Lightweight folder visual for empty-folder states.
struct FolderBadgeView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Colors.orangePrimary.opacity(0.22))
                .frame(width: 74, height: 52)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.Colors.orangePrimary.opacity(0.32))
                .frame(width: 26, height: 10)
                .offset(x: -38, y: -6)
            Image(systemName: "doc")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .offset(x: -8, y: -8)
        }
    }
}
