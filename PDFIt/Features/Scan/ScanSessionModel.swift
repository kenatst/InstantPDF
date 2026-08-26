import Foundation
import UIKit
import CoreImage

/// One scanned page in the review flow. The enhanced image is written to a
/// staged file immediately (enhance-in-place) so memory never holds more
/// than one decoded bitmap at a time.
struct ScannedPage: Identifiable, Equatable {
    let id: UUID
    /// Staged JPEG path of the CURRENT enhanced image.
    var imageURL: URL
    var rotationQuarterTurns: Int = 0
    var enhancement: ScanEnhancement = .original

    static func == (lhs: ScannedPage, rhs: ScannedPage) -> Bool {
        lhs.id == rhs.id && lhs.imageURL == rhs.imageURL
            && lhs.rotationQuarterTurns == rhs.rotationQuarterTurns
            && lhs.enhancement == rhs.enhancement
    }
}

/// Fast, understandable scan enhancements. No filter zoo.
enum ScanEnhancement: String, CaseIterable, Identifiable {
    case original
    case color
    case document
    case blackAndWhite

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .original: return "Original"
        case .color: return "Color"
        case .document: return "Document"
        case .blackAndWhite: return "Black & White"
        }
    }

    // MARK: - Pipeline

    /// Applies the preset to `input` and returns processed data.
    /// Pure function of input pixels — deterministic and testable.
    static func processData(_ data: Data, enhancement: ScanEnhancement) -> Data {
        guard enhancement != .original else { return data }
        guard let image = UIImage(data: data)?.cgImage else { return data }
        guard let output = process(image, enhancement: enhancement),
              let jpeg = uiImageFromCG(output).jpegData(compressionQuality: 0.82) else {
            return data
        }
        return jpeg
    }

    static func process(_ input: CGImage, enhancement: ScanEnhancement) -> CGImage? {
        let ciContext = CIContext()
        var ci = CIImage(cgImage: input)

        switch enhancement {
        case .original:
            return input
        case .color:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.12,
                kCIInputContrastKey: 1.08,
                kCIInputBrightnessKey: 0.02,
            ])
        case .document:
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.35,
                kCIInputContrastKey: 1.28,
                kCIInputBrightnessKey: 0.05,
            ])
            ci = ci.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 2.2,
                kCIInputIntensityKey: 0.6,
            ])
        case .blackAndWhite:
            ci = ci.applyingFilter("CIPhotoEffectMono")
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.22,
                kCIInputBrightnessKey: 0.04,
            ])
        }

        guard let rendered = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return rendered
    }

    private static func uiImageFromCG(_ cg: CGImage) -> UIImage {
        UIImage(cgImage: cg)
    }
}

/// Pure model for one scanned document group (batch workflow).
struct ScanGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var pageIDs: [UUID]

    init(id: UUID = UUID(), name: String, pageIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.pageIDs = pageIDs
    }
}

/// Deterministic model behind the scan review + batch flows. All mutations
/// are pure value-type operations — fully unit-testable without camera.
struct ScanSessionModel: Equatable {
    var pages: [ScannedPage] = []
    var groups: [ScanGroup] = []

    var isEmpty: Bool { pages.isEmpty }

    // MARK: - Page lifecycle

    mutating func append(page: ScannedPage) {
        pages.append(page)
        if groups.isEmpty {
            groups = [ScanGroup(name: "Document 1")]
        }
        // Every page lives in exactly one group; default to the last.
        groups[groups.count - 1].pageIDs.append(page.id)
    }

    mutating func removePage(id: UUID) {
        pages.removeAll { $0.id == id }
        for index in groups.indices {
            groups[index].pageIDs.removeAll { $0 == id }
        }
        pruneEmptyTrailingGroups()
    }

    mutating func rotatePage(id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].rotationQuarterTurns = (pages[index].rotationQuarterTurns + 1) % 4
    }

    mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        pages.move(fromOffsets: fromOffsets, toOffset: toOffset)
        rebuildGroupsPreservingOrder()
    }

    mutating func setEnhancement(_ enhancement: ScanEnhancement, forPageID id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].enhancement = enhancement
    }

    mutating func setEnhancementAllPages(_ enhancement: ScanEnhancement) {
        for index in pages.indices {
            pages[index].enhancement = enhancement
        }
    }

    // MARK: - Batch grouping

    /// Starts a new empty document group. The next captured page is appended
    /// to it; cancelling that capture removes the empty trailing group.
    mutating func beginNewGroup() {
        guard let last = groups.last, !last.pageIDs.isEmpty else { return }
        groups.append(ScanGroup(name: "Document \(groups.count + 1)"))
    }

    mutating func discardEmptyTrailingGroup() {
        guard let last = groups.last, last.pageIDs.isEmpty else { return }
        groups.removeLast()
    }

    /// Splits trailing pages into a new group starting at `fromPageIndex`.
    mutating func insertGroupBreak(afterPageIndex index: Int) {
        if groups.isEmpty {
            groups = [ScanGroup(name: "Document 1")]
        }
        let sourceGroup = lastGroupIndex
        let splitIDs = Array(groups[sourceGroup].pageIDs.dropFirst(index + 1))
        guard !splitIDs.isEmpty else { return }
        groups[sourceGroup].pageIDs.removeSubrange((index + 1)...)
        groups.append(ScanGroup(name: "Document \(groups.count + 1)", pageIDs: splitIDs))
    }

    mutating func removeGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let removedIDs = Set(groups[index].pageIDs)
        pages.removeAll { removedIDs.contains($0.id) }
        groups.remove(at: index)
        pruneEmptyTrailingGroups()
    }

    mutating func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[index].name = trimmed.isEmpty ? groups[index].name : String(trimmed.prefix(80))
    }

    mutating func moveGroups(fromOffsets: IndexSet, toOffset: Int) {
        groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Moves a page into an adjacent group (`+1` / `-1`).
    mutating func movePage(id: UUID, toAdjacentGroup offset: Int) {
        guard let fromIndex = groups.firstIndex(where: { $0.pageIDs.contains(id) }) else { return }
        let target = fromIndex + offset
        guard groups.indices.contains(target) else { return }
        groups[fromIndex].pageIDs.removeAll { $0 == id }
        groups[target].pageIDs.append(id)
        pruneEmptyMiddleGroups()
    }

    /// Pages in visual (reordered) order, filtered per group.
    func pages(in group: ScanGroup) -> [ScannedPage] {
        group.pageIDs.compactMap { id in pages.first { $0.id == id } }
    }

    var orderedGroups: [(group: ScanGroup, pages: [ScannedPage])] {
        groups.map { ($0, pages(in: $0)) }
    }

    // MARK: - Invariants

    private var lastGroupIndex: Int { max(0, groups.count - 1) }

    private mutating func pruneEmptyTrailingGroups() {
        while let last = groups.last, last.pageIDs.isEmpty {
            groups.removeLast()
        }
        if groups.isEmpty && !pages.isEmpty {
            groups = [ScanGroup(name: "Document 1", pageIDs: pages.map(\.id))]
        }
    }

    private mutating func pruneEmptyMiddleGroups() {
        let keepID = groups.last?.id
        groups.removeAll { $0.pageIDs.isEmpty && $0.id != keepID }
        pruneEmptyTrailingGroups()
    }

    /// After manual reordering of `pages`, regenerate group membership so
    /// each contiguous run stays consistent with visual order.
    private mutating func rebuildGroupsPreservingOrder() {
        let membership = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.pageIDs.map { ($0, group.id) }
        })
        var rebuilt: [ScanGroup] = []
        for page in pages {
            let ownerID = membership[page.id]
            if let last = rebuilt.last, last.id == ownerID {
                rebuilt[rebuilt.count - 1].pageIDs.append(page.id)
            } else if let ownerID,
                      let existing = rebuilt.firstIndex(where: { $0.id == ownerID }) {
                // Group reappears after an interleaved reorder: fold into it.
                rebuilt[existing].pageIDs.append(page.id)
            } else {
                rebuilt.append(ScanGroup(id: ownerID ?? UUID(),
                                         name: groupName(forOwner: ownerID),
                                         pageIDs: [page.id]))
            }
        }
        groups = rebuilt.isEmpty ? [] : rebuilt
    }

    private var originalNames: [UUID: String] {
        [:]
    }

    private func groupName(forOwner ownerID: UUID?) -> String {
        guard let ownerID,
              let original = groups.first(where: { $0.id == ownerID }) else {
            return "Document \(groups.count + 1)"
        }
        return original.name
    }
}
