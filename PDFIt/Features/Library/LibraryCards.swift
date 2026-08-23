import SwiftUI
import PDFKit

/// The PDF grid card: real thumbnail, title, source badge, pages, size, date.
/// `showBadge` is disabled in selection mode (the checkmark replaces it).
struct LibraryGridCard: View {
    let record: StoredPDFRecord
    var showBadge: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // PDF Preview thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "F2F4F7"))

                if let image = StorageManager.shared.thumbnailImage(for: record) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 150)
                        .clipped()
                        .cornerRadius(12)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Colors.orangePrimary.opacity(0.8))
                }
            }
            .frame(height: 150)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Label {
                        Text(String(localized: "plural.pages \(record.pageCount)"))
                    } icon: {
                        Image(systemName: record.contentSource.symbolName)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                }
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.55) : Color.secondary)

                Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.45) : Color.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
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
