import Foundation

@main struct GalleryOrderingTests {
    static func main() throws {
        let projectID = UUID()
        let ids = (0..<5).map { _ in UUID() }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name)
            checks += 1
        }
        for source in ids {
            let payload = GalleryDragPayload(projectID: projectID, imageID: source)
            for target in ids {
                for after in [false, true] {
                    let result = GalleryOrdering.order(for: payload, projectID: projectID, currentIDs: ids, targetID: target, after: after)!
                    check(result.count == ids.count && Set(result) == Set(ids), "every drop remains an exact permutation")
                    check(result.filter { $0 != source } == ids.filter { $0 != source }, "non-dragged images retain relative order")
                    if source == target {
                        check(result == ids, "dropping onto itself leaves order intact")
                    } else {
                        let sourceIndex = result.firstIndex(of: source)!, targetIndex = result.firstIndex(of: target)!
                        check(after ? sourceIndex == targetIndex + 1 : sourceIndex + 1 == targetIndex, "drop honors insertion side")
                    }
                }
            }
            let end = GalleryOrdering.order(for: payload, projectID: projectID, currentIDs: ids, targetID: nil, after: true)!
            check(end.last == source && Array(end.dropLast()) == ids.filter { $0 != source }, "end target appends without reordering others")
            let encoded = try JSONEncoder().encode(payload)
            let decoded = try JSONDecoder().decode(GalleryDragPayload.self, from: encoded)
            check(decoded == payload, "native pasteboard payload preserves both identities")
        }
        let payload = GalleryDragPayload(projectID: projectID, imageID: ids[0])
        check(GalleryOrdering.order(for: payload, projectID: UUID(), currentIDs: ids, targetID: ids[2], after: false) == nil, "cross-project drop rejected")
        check(GalleryOrdering.order(for: GalleryDragPayload(projectID: projectID, imageID: UUID()), projectID: projectID, currentIDs: ids, targetID: ids[2], after: false) == nil, "stale source rejected")
        check(GalleryOrdering.order(for: payload, projectID: projectID, currentIDs: ids, targetID: UUID(), after: false) == nil, "stale insertion target rejected")
        check(GalleryOrdering.order(for: payload, projectID: projectID, currentIDs: ids + [ids[0]], targetID: ids[2], after: false) == nil, "corrupt repeated IDs rejected")
        check(GalleryOrdering.order(for: payload, projectID: projectID, currentIDs: [], targetID: nil, after: true) == nil, "empty gallery rejects stale drag")
        let changedDuringDrag = [ids[4], ids[3], ids[2], ids[1], ids[0]]
        let currentResult = GalleryOrdering.order(for: payload, projectID: projectID, currentIDs: changedDuringDrag, targetID: ids[3], after: false)!
        check(currentResult == [ids[4], ids[0], ids[3], ids[2], ids[1]], "drop resolves against current order rather than drag-start indices")
        print("\(checks) GALLERY ORDERING CHECKS PASSED")
    }
}
