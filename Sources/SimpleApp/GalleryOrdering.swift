import Foundation

struct GalleryDragPayload: Codable, Equatable {
    let projectID: UUID
    let imageID: UUID
}

/// Resolves an insertion against the current persisted gallery, not the drag's old index.
enum GalleryOrdering {
    static func order(for payload: GalleryDragPayload, projectID: UUID, currentIDs: [UUID], targetID: UUID?, after: Bool) -> [UUID]? {
        guard payload.projectID == projectID,
              Set(currentIDs).count == currentIDs.count,
              currentIDs.contains(payload.imageID) else { return nil }
        if targetID == payload.imageID { return currentIDs }
        var reordered = currentIDs.filter { $0 != payload.imageID }
        if let targetID {
            guard let targetIndex = reordered.firstIndex(of: targetID) else { return nil }
            reordered.insert(payload.imageID, at: targetIndex + (after ? 1 : 0))
        } else {
            reordered.append(payload.imageID)
        }
        return reordered
    }
}
