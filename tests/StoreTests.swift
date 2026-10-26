import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct StoreTests {
    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("YingGaoStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let source = temp.appendingPathComponent("fixture.png")
        let context = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("fixture write failed") }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
            print("PASS \(message)")
        }
        func expectError(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected failure: \(message)") }
            catch { count += 1; print("PASS \(message)") }
        }
        func snapshotMatches(_ actual: ProjectImage?, _ expected: ProjectImage) -> Bool {
            guard let actual else { return false }
            // Metadata dates are serialized as milliseconds, so tolerate submillisecond rounding.
            return actual.id == expected.id && actual.filename == expected.filename &&
                actual.fixedPrompt == expected.fixedPrompt && actual.variablePrompt == expected.variablePrompt &&
                actual.threadID == expected.threadID && actual.turnID == expected.turnID &&
                abs(actual.createdAt.timeIntervalSince(expected.createdAt)) < 0.001
        }
        func snapshotsMatch(_ actual: [ProjectImage]?, _ expected: [ProjectImage]) -> Bool {
            guard let actual, actual.count == expected.count else { return false }
            return zip(actual, expected).allSatisfy { snapshotMatches($0.0, $0.1) }
        }

        let store = ProjectStore(root: temp.appendingPathComponent("projects"))
        try store.load()
        let a = try store.create(name: "  项目甲  ")
        let b = try store.create(name: "项目乙")
        try store.updatePrompts(projectID: a, fixed: "固定风格", variable: "第一张")
        let image1 = try store.stageImage(projectID: a, source: source, fixed: "固定风格", variable: "第一张", threadID: "thread-1", turnID: "turn-1")
        check(store.projects.first(where: { $0.id == a })?.name == "项目甲", "project name trimmed")
        check(store.projects.first(where: { $0.id == b })?.pendingImage == nil, "staged image isolated from second project")
        let copiedBytes = try Data(contentsOf: store.imageURL(projectID: a, image: image1))
        let sourceBytes = try Data(contentsOf: source)
        check(copiedBytes == sourceBytes, "original image bytes copied without transformation")
        let reloaded = ProjectStore(root: store.rootURL)
        try reloaded.load()
        check(reloaded.projects.count == 2, "projects survive reload")
        check(reloaded.projects.first(where: { $0.id == a })?.pendingImage?.id == image1.id, "pending image survives reload")
        check(reloaded.projects.first(where: { $0.id == a })?.fixedPrompt == "固定风格", "fixed prompt persists")
        try reloaded.confirmImage(projectID: a, imageID: image1.id)
        try reloaded.confirmImage(projectID: a, imageID: image1.id)
        check(reloaded.projects.first(where: { $0.id == a })?.confirmedImages.count == 1, "confirmation is idempotent")
        check(reloaded.projects.first(where: { $0.id == a })?.pendingImage == nil, "confirmation consumes pending selection")
        let image2 = try reloaded.stageImage(projectID: a, source: source, fixed: "新风格", variable: "第二张", threadID: "thread-2", turnID: "turn-2")
        expectError("stale candidate cannot be confirmed") { try reloaded.confirmImage(projectID: a, imageID: UUID()) }
        check(reloaded.projects.first(where: { $0.id == a })?.confirmedImages.first?.id == image1.id, "new generation never replaces confirmed image")
        try reloaded.updatePrompts(projectID: a, fixed: "实时修改", variable: "下一张")
        check(reloaded.projects.first(where: { $0.id == a })?.pendingImage?.variablePrompt == "第二张", "image keeps original input snapshot")
        check(reloaded.projects.first(where: { $0.id == a })?.pendingImage?.id == image2.id, "prompt edits preserve pending candidate")
        let bad = temp.appendingPathComponent("invalid.png")
        try Data("not image data".utf8).write(to: bad)
        expectError("invalid image rejected") { _ = try reloaded.stageImage(projectID: a, source: bad, fixed: "", variable: "", threadID: nil, turnID: nil) }
        check(reloaded.projects.first(where: { $0.id == a })?.pendingImage?.id == image2.id, "invalid image does not change pending candidate")
        let blockedBackup = reloaded.projectFolder(b).appendingPathComponent("project.backup.json")
        try fm.createDirectory(at: blockedBackup, withIntermediateDirectories: false)
        expectError("failed metadata write is surfaced") { try reloaded.updatePrompts(projectID: b, fixed: "will fail", variable: "") }
        check(reloaded.projects.first(where: { $0.id == b })?.fixedPrompt == "", "failed write rolls back memory")
        let assetsBefore = try fm.contentsOfDirectory(atPath: reloaded.projectFolder(b).appendingPathComponent("assets").path)
        expectError("failed staging metadata write is surfaced") { _ = try reloaded.stageImage(projectID: b, source: source, fixed: "", variable: "", threadID: nil, turnID: nil) }
        let assetsAfter = try fm.contentsOfDirectory(atPath: reloaded.projectFolder(b).appendingPathComponent("assets").path)
        check(assetsBefore == assetsAfter, "failed staging removes only the newly copied candidate")
        try fm.removeItem(at: blockedBackup)
        try Data("corrupt".utf8).write(to: reloaded.projectFolder(a).appendingPathComponent("project.json"))
        let recovered = ProjectStore(root: store.rootURL)
        try recovered.load()
        check(recovered.projects.count == 2, "valid backup recovers damaged project without hiding other project")
        check(recovered.errorMessage?.contains("备份恢复") == true, "recovery shown to user")
        let files = try fm.contentsOfDirectory(atPath: recovered.projectFolder(a).path)
        check(files.contains(where: { $0.hasPrefix("project.corrupt-") }), "corrupt metadata retained for inspection")
        var hostile = recovered.projects.first(where: { $0.id == b })!
        var evilImage = image1
        evilImage.filename = "../../outside.png"
        hostile.confirmedImages = [evilImage]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(hostile).write(to: recovered.projectFolder(b).appendingPathComponent("project.json"))
        try recovered.load()
        check(recovered.projects.count == 1, "unsafe project record skipped while valid project remains")
        check(recovered.errorMessage?.contains("无法读取") == true, "unrecoverable corruption reported")
        check(recovered.imageURL(projectID: a, image: evilImage).lastPathComponent == "invalid-image", "path traversal cannot escape asset directory")
        let c = try recovered.create(name: "symlink test")
        let assetDirectory = recovered.projectFolder(c).appendingPathComponent("assets")
        try fm.removeItem(at: assetDirectory)
        try fm.createSymbolicLink(at: assetDirectory, withDestinationURL: recovered.projectFolder(a).appendingPathComponent("assets"))
        expectError("cross-project asset directory symlink rejected") { _ = try recovered.stageImage(projectID: c, source: source, fixed: "", variable: "", threadID: nil, turnID: nil) }
        expectError("blank project name rejected") { _ = try recovered.create(name: " \n ") }

        let trashRoot = temp.appendingPathComponent("trash-projects")
        var trashStore = ProjectStore(root: trashRoot)
        try trashStore.load()
        let trashProject = try trashStore.create(name: "垃圾箱测试")
        let otherProject = try trashStore.create(name: "隔离项目")
        let first = try trashStore.stageImage(projectID: trashProject, source: source, fixed: "原始固定提示词", variable: "原始第一张", threadID: "original-thread", turnID: "original-turn")
        try trashStore.confirmImage(projectID: trashProject, imageID: first.id)
        let second = try trashStore.stageImage(projectID: trashProject, source: source, fixed: "第二张风格", variable: "第二张内容", threadID: nil, turnID: nil)
        try trashStore.confirmImage(projectID: trashProject, imageID: second.id)
        let pending = try trashStore.stageImage(projectID: trashProject, source: source, fixed: "待确认风格", variable: "待确认内容", threadID: nil, turnID: nil)
        let primary = trashStore.projectFolder(trashProject).appendingPathComponent("project.json")
        let trashBackup = trashStore.projectFolder(trashProject).appendingPathComponent("project.backup.json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: primary)) as! [String: Any]
        legacy.removeValue(forKey: "trashedImages")
        try JSONSerialization.data(withJSONObject: legacy).write(to: primary, options: .atomic)
        trashStore = ProjectStore(root: trashRoot)
        try trashStore.load()
        check(trashStore.projects.first(where: { $0.id == trashProject })?.trashedImages.isEmpty == true, "legacy project without trash key loads with empty trash")
        check(snapshotsMatch(trashStore.projects.first(where: { $0.id == trashProject })?.confirmedImages, [first, second]), "legacy migration preserves complete confirmed records")
        expectError("pending image cannot be moved to trash") { try trashStore.moveImageToTrash(projectID: trashProject, imageID: pending.id) }
        expectError("foreign project cannot trash image") { try trashStore.moveImageToTrash(projectID: otherProject, imageID: first.id) }
        expectError("foreign project cannot restore image") { try trashStore.restoreImage(projectID: otherProject, imageID: first.id) }
        let beforeFailedMove = trashStore.projects
        let primaryBeforeFailedMove = try Data(contentsOf: primary)
        let backupBeforeFailedMove = try Data(contentsOf: trashBackup)
        try fm.removeItem(at: trashBackup)
        try fm.createDirectory(at: trashBackup, withIntermediateDirectories: false)
        expectError("trash metadata save failure is surfaced") { try trashStore.moveImageToTrash(projectID: trashProject, imageID: first.id) }
        check(trashStore.projects == beforeFailedMove, "failed trash save preserves published gallery and pending")
        let primaryAfterFailedMove = try Data(contentsOf: primary)
        check(primaryAfterFailedMove == primaryBeforeFailedMove, "failed trash save preserves on-disk record")
        try fm.removeItem(at: trashBackup)
        try backupBeforeFailedMove.write(to: trashBackup, options: .atomic)
        let firstURL = trashStore.imageURL(projectID: trashProject, image: first)
        let firstBytes = try Data(contentsOf: firstURL)
        try trashStore.moveImageToTrash(projectID: trashProject, imageID: first.id)
        try trashStore.moveImageToTrash(projectID: trashProject, imageID: first.id)
        check(snapshotsMatch(trashStore.projects.first(where: { $0.id == trashProject })?.confirmedImages, [second]), "trash removes only selected confirmed image")
        check(trashStore.projects.first(where: { $0.id == trashProject })?.trashedImages.count == 1, "repeated trash operation is idempotent")
        check(snapshotMatches(trashStore.projects.first(where: { $0.id == trashProject })?.pendingImage, pending), "trash leaves pending image unchanged")
        check(trashStore.projects.first(where: { $0.id == otherProject })?.trashedImages.isEmpty == true, "trash is isolated per project")
        let afterTrashBytes = try Data(contentsOf: firstURL)
        check(afterTrashBytes == firstBytes, "trash retains exact original file at same path")
        trashStore = ProjectStore(root: trashRoot)
        try trashStore.load()
        let savedTrash = trashStore.projects.first(where: { $0.id == trashProject })?.trashedImages.first
        check(snapshotMatches(savedTrash?.image, first) && savedTrash?.deletedAt != nil, "trash reload preserves image snapshot and deletion time")

        let beforeFailedRestore = trashStore.projects
        let primaryBeforeFailedRestore = try Data(contentsOf: primary)
        let backupBeforeFailedRestore = try Data(contentsOf: trashBackup)
        try fm.removeItem(at: trashBackup)
        try fm.createDirectory(at: trashBackup, withIntermediateDirectories: false)
        expectError("restore metadata save failure is surfaced") { try trashStore.restoreImage(projectID: trashProject, imageID: first.id) }
        check(trashStore.projects == beforeFailedRestore, "failed restore keeps image in trash and gallery unchanged")
        let primaryAfterFailedRestore = try Data(contentsOf: primary)
        check(primaryAfterFailedRestore == primaryBeforeFailedRestore, "failed restore preserves on-disk record")
        try fm.removeItem(at: trashBackup)
        try backupBeforeFailedRestore.write(to: trashBackup, options: .atomic)
        try trashStore.restoreImage(projectID: trashProject, imageID: first.id)
        try trashStore.restoreImage(projectID: trashProject, imageID: first.id)
        trashStore = ProjectStore(root: trashRoot)
        try trashStore.load()
        check(snapshotsMatch(trashStore.projects.first(where: { $0.id == trashProject })?.confirmedImages, [second, first]), "restored original appends to gallery once and survives reload")
        check(trashStore.projects.first(where: { $0.id == trashProject })?.trashedImages.isEmpty == true, "restored image leaves trash after reload")
        check(snapshotMatches(trashStore.projects.first(where: { $0.id == trashProject })?.pendingImage, pending), "restore leaves pending image untouched")
        let restoredBytes = try Data(contentsOf: firstURL)
        check(restoredBytes == firstBytes, "restore preserves original bytes and path")

        try trashStore.moveImageToTrash(projectID: trashProject, imageID: first.id)
        try trashStore.moveImageToTrash(projectID: trashProject, imageID: second.id)
        trashStore = ProjectStore(root: trashRoot)
        try trashStore.load()
        check(Set(trashStore.projects.first(where: { $0.id == trashProject })!.trashedImages.map(\.id)) == Set([first.id, second.id]), "multiple trashed images survive reload independently")
        try trashStore.restoreImage(projectID: trashProject, imageID: second.id)
        check(trashStore.projects.first(where: { $0.id == trashProject })?.trashedImages.map(\.id) == [first.id], "restoring one image leaves other trash intact")

        let invalidStore = ProjectStore(root: temp.appendingPathComponent("invalid-trash-projects"))
        try invalidStore.load()
        let invalidProject = try invalidStore.create(name: "非法记录测试")
        var invalidRecord = invalidStore.projects.first!
        invalidRecord.confirmedImages = [first]
        invalidRecord.trashedImages = [TrashedProjectImage(image: first, deletedAt: Date())]
        let invalidPrimary = invalidStore.projectFolder(invalidProject).appendingPathComponent("project.json")
        try encoder.encode(invalidRecord).write(to: invalidPrimary, options: .atomic)
        try invalidStore.load()
        check(invalidStore.projects.isEmpty, "duplicate image across gallery and trash is rejected")
        invalidRecord.confirmedImages = []
        invalidRecord.trashedImages = [TrashedProjectImage(image: first, deletedAt: Date()), TrashedProjectImage(image: first, deletedAt: Date())]
        try encoder.encode(invalidRecord).write(to: invalidPrimary, options: .atomic)
        try invalidStore.load()
        check(invalidStore.projects.isEmpty, "duplicate images within trash are rejected")
        invalidRecord.trashedImages = [TrashedProjectImage(image: evilImage, deletedAt: Date())]
        try encoder.encode(invalidRecord).write(to: invalidPrimary, options: .atomic)
        try invalidStore.load()
        check(invalidStore.projects.isEmpty, "unsafe trash asset path is rejected")

        let batchRoot = temp.appendingPathComponent("batch-projects")
        var batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        let batchProject = try batchStore.create(name: "三图与排序")
        let untouchedProject = try batchStore.create(name: "另一个项目")
        try batchStore.updatePrompts(projectID: batchProject, fixed: "整个项目的风格", variable: "当前草稿")
        let legacyCandidate = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "旧版风格", variable: "旧版候选", threadID: "old-thread", turnID: "old-turn")
        let batchPrimary = batchStore.projectFolder(batchProject).appendingPathComponent("project.json")
        let batchBackup = batchStore.projectFolder(batchProject).appendingPathComponent("project.backup.json")
        var oldSingleRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: batchPrimary)) as! [String: Any]
        oldSingleRecord["pendingImage"] = (oldSingleRecord.removeValue(forKey: "pendingImages") as! [[String: Any]]).first!
        oldSingleRecord.removeValue(forKey: "deletedAt")
        try JSONSerialization.data(withJSONObject: oldSingleRecord).write(to: batchPrimary, options: .atomic)
        batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        check(snapshotsMatch(batchStore.projects.first(where: { $0.id == batchProject })?.pendingImages, [legacyCandidate]), "legacy one-image record migrates to one candidate with full snapshot")
        check(batchStore.activeProjects.count == 2 && batchStore.deletedProjects.isEmpty, "legacy records without deletedAt remain active")

        func withBlockedBatchBackup(_ operation: () throws -> Void) throws {
            let backup = try Data(contentsOf: batchBackup)
            try fm.removeItem(at: batchBackup)
            try fm.createDirectory(at: batchBackup, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: batchBackup); try? backup.write(to: batchBackup, options: .atomic) }
            try operation()
        }
        let beforeReplaceFailure = batchStore.projects
        try withBlockedBatchBackup {
            expectError("failed new-batch staging is surfaced") { _ = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "", variable: "", threadID: nil, turnID: nil) }
        }
        check(batchStore.projects == beforeReplaceFailure, "failed replacement preserves old pending batch and trash")
        let option1 = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "同一固定提示词", variable: "候选一", threadID: "batch-thread-1", turnID: "batch-turn-1")
        let option2 = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "同一固定提示词", variable: "候选二", threadID: "batch-thread-2", turnID: "batch-turn-2", appendToPending: true)
        let option3 = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "同一固定提示词", variable: "候选三", threadID: "batch-thread-3", turnID: "batch-turn-3", appendToPending: true)
        batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        check(snapshotsMatch(batchStore.projects.first(where: { $0.id == batchProject })?.pendingImages, [option1, option2, option3]), "three independent candidates and snapshots survive reload in generation order")
        check(snapshotMatches(batchStore.projects.first(where: { $0.id == batchProject })?.trashedImages.first?.image, legacyCandidate), "successful new batch retains superseded candidate in trash")
        expectError("fourth pending image is rejected") { _ = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "", variable: "", threadID: nil, turnID: nil, appendToPending: true) }
        check(batchStore.projects.first(where: { $0.id == batchProject })?.pendingImages.count == 3, "full candidate batch remains intact after extra append")
        let beforeConfirmFailure = batchStore.projects
        let diskBeforeConfirmFailure = try Data(contentsOf: batchPrimary)
        try withBlockedBatchBackup {
            expectError("failed choice confirmation is surfaced") { try batchStore.confirmImage(projectID: batchProject, imageID: option2.id) }
        }
        check(batchStore.projects == beforeConfirmFailure, "failed choice confirmation preserves all candidates in memory")
        let diskAfterConfirmFailure = try Data(contentsOf: batchPrimary)
        check(diskAfterConfirmFailure == diskBeforeConfirmFailure, "failed choice confirmation preserves persisted candidate batch")
        try batchStore.confirmImage(projectID: batchProject, imageID: option2.id)
        try batchStore.confirmImage(projectID: batchProject, imageID: option2.id)
        batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        check(snapshotsMatch(batchStore.projects.first(where: { $0.id == batchProject })?.confirmedImages, [option2]), "choosing the middle candidate adds exactly that image once")
        check(batchStore.projects.first(where: { $0.id == batchProject })?.pendingImages.isEmpty == true, "confirming a choice consumes the whole candidate batch")
        check(Set(batchStore.projects.first(where: { $0.id == batchProject })!.trashedImages.map(\.id)) == Set([legacyCandidate.id, option1.id, option3.id]), "unselected candidates remain recoverable with previous candidate")
        let allOriginalsPreserved = try [legacyCandidate, option1, option2, option3].allSatisfy { try Data(contentsOf: batchStore.imageURL(projectID: batchProject, image: $0)) == sourceBytes }
        check(allOriginalsPreserved, "choosing one candidate never deletes or transforms any original")
        check(batchStore.projects.first(where: { $0.id == untouchedProject })?.allImages.isEmpty == true, "candidate batch changes stay inside its project")

        try batchStore.restoreImage(projectID: batchProject, imageID: option1.id)
        try batchStore.restoreImage(projectID: batchProject, imageID: option3.id)
        try batchStore.reorderConfirmedImages(projectID: batchProject, orderedIDs: [option3.id, option2.id, option1.id])
        batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        check(snapshotsMatch(batchStore.projects.first(where: { $0.id == batchProject })?.confirmedImages, [option3, option2, option1]), "gallery reordering persists exact image order and snapshots")
        let beforeInvalidOrders = batchStore.projects
        expectError("duplicate IDs in gallery order are rejected") { try batchStore.reorderConfirmedImages(projectID: batchProject, orderedIDs: [option3.id, option2.id, option2.id]) }
        expectError("incomplete gallery order is rejected") { try batchStore.reorderConfirmedImages(projectID: batchProject, orderedIDs: [option3.id, option2.id]) }
        expectError("foreign image in gallery order is rejected") { try batchStore.reorderConfirmedImages(projectID: batchProject, orderedIDs: [option3.id, option2.id, UUID()]) }
        check(batchStore.projects == beforeInvalidOrders, "rejected gallery orders leave all project data unchanged")
        let orderDiskBefore = try Data(contentsOf: batchPrimary)
        try withBlockedBatchBackup {
            expectError("failed reorder save is surfaced") { try batchStore.reorderConfirmedImages(projectID: batchProject, orderedIDs: [option1.id, option2.id, option3.id]) }
        }
        check(batchStore.projects == beforeInvalidOrders, "failed reorder save preserves published gallery order")
        let orderDiskAfter = try Data(contentsOf: batchPrimary)
        check(orderDiskAfter == orderDiskBefore, "failed reorder save preserves persisted gallery order")

        let finalPending = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "删除项目前候选", variable: "仍可恢复", threadID: nil, turnID: nil)
        let projectBeforeDeletion = batchStore.projects.first(where: { $0.id == batchProject })!
        let beforeProjectDeleteFailure = batchStore.projects
        try withBlockedBatchBackup {
            expectError("failed project deletion save is surfaced") { try batchStore.moveProjectToTrash(projectID: batchProject) }
        }
        check(batchStore.projects == beforeProjectDeleteFailure && batchStore.activeProjects.count == 2, "failed project deletion keeps project active and all contents unchanged")
        try batchStore.moveProjectToTrash(projectID: batchProject)
        let firstDeletedAt = batchStore.projects.first(where: { $0.id == batchProject })!.deletedAt
        try batchStore.moveProjectToTrash(projectID: batchProject)
        check(batchStore.projects.first(where: { $0.id == batchProject })!.deletedAt == firstDeletedAt, "repeated project deletion does not reset deletion time")
        batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        check(batchStore.activeProjects.map(\.id) == [untouchedProject] && batchStore.deletedProjects.map(\.id) == [batchProject], "deleted projects are hidden from active list and retained across reload")
        let deletedProject = batchStore.projects.first(where: { $0.id == batchProject })!
        check(snapshotsMatch(deletedProject.allImages, projectBeforeDeletion.allImages) && deletedProject.fixedPrompt == projectBeforeDeletion.fixedPrompt && deletedProject.variablePrompt == projectBeforeDeletion.variablePrompt, "project deletion preserves gallery order, pending, trash, and prompt snapshots")
        expectError("deleted project rejects prompt edits") { try batchStore.updatePrompts(projectID: batchProject, fixed: "", variable: "") }
        expectError("deleted project rejects incoming generation") { _ = try batchStore.stageImage(projectID: batchProject, source: source, fixed: "", variable: "", threadID: nil, turnID: nil) }
        expectError("deleted project rejects candidate confirmation") { try batchStore.confirmImage(projectID: batchProject, imageID: finalPending.id) }
        expectError("deleted project rejects image deletion") { try batchStore.moveImageToTrash(projectID: batchProject, imageID: option1.id) }
        expectError("deleted project rejects image restoration") { try batchStore.restoreImage(projectID: batchProject, imageID: legacyCandidate.id) }
        expectError("deleted project rejects gallery reorder") { try batchStore.reorderConfirmedImages(projectID: batchProject, orderedIDs: [option3.id, option2.id, option1.id]) }
        let beforeProjectRestoreFailure = batchStore.projects
        let restoreProjectDiskBefore = try Data(contentsOf: batchPrimary)
        try withBlockedBatchBackup {
            expectError("failed project restore save is surfaced") { try batchStore.restoreProject(projectID: batchProject) }
        }
        check(batchStore.projects == beforeProjectRestoreFailure && batchStore.deletedProjects.count == 1, "failed project restore keeps complete project in trash")
        let restoreProjectDiskAfter = try Data(contentsOf: batchPrimary)
        check(restoreProjectDiskBefore == restoreProjectDiskAfter, "failed project restore preserves persisted deletion state")
        try batchStore.restoreProject(projectID: batchProject)
        try batchStore.restoreProject(projectID: batchProject)
        batchStore = ProjectStore(root: batchRoot)
        try batchStore.load()
        let restoredProject = batchStore.projects.first(where: { $0.id == batchProject })!
        check(batchStore.activeProjects.count == 2 && batchStore.deletedProjects.isEmpty, "restored project returns to active list after reload without duplication")
        check(snapshotsMatch(restoredProject.allImages, projectBeforeDeletion.allImages) && restoredProject.fixedPrompt == projectBeforeDeletion.fixedPrompt && restoredProject.variablePrompt == projectBeforeDeletion.variablePrompt, "project restoration preserves every record and gallery order")
        let restoredOriginalsPreserved = try restoredProject.allImages.allSatisfy { try Data(contentsOf: batchStore.imageURL(projectID: batchProject, image: $0)) == sourceBytes }
        check(restoredOriginalsPreserved, "project trash and restore retain exact image bytes")

        invalidRecord.trashedImages = []
        invalidRecord.confirmedImages = []
        invalidRecord.pendingImages = [first, first]
        try encoder.encode(invalidRecord).write(to: invalidPrimary, options: .atomic)
        try invalidStore.load()
        check(invalidStore.projects.isEmpty, "duplicate pending candidate IDs are rejected")
        invalidRecord.pendingImages = [first]
        invalidRecord.confirmedImages = [first]
        try encoder.encode(invalidRecord).write(to: invalidPrimary, options: .atomic)
        try invalidStore.load()
        check(invalidStore.projects.isEmpty, "candidate cannot also appear in gallery")
        print("\(count) STORE CHECKS PASSED")
    }
}
