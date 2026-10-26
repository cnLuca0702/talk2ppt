import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

struct ProjectImage: Identifiable, Codable, Equatable {
    var id: UUID
    var filename: String
    var fixedPrompt: String
    var variablePrompt: String
    var createdAt: Date
    var threadID: String?
    var turnID: String?
}

struct TrashedProjectImage: Identifiable, Codable, Equatable {
    var image: ProjectImage
    var deletedAt: Date
    var id: UUID { image.id }
}

struct SimpleProject: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var fixedPrompt: String
    var variablePrompt: String
    var createdAt: Date
    var updatedAt: Date
    var pendingImages: [ProjectImage]
    var confirmedImages: [ProjectImage]
    var trashedImages: [TrashedProjectImage] = []
    var deletedAt: Date? = nil

    // Read compatibility for the first-generation one-image UI and local harnesses.
    var pendingImage: ProjectImage? {
        get { pendingImages.first }
        set { pendingImages = newValue.map { [$0] } ?? [] }
    }

    var allImages: [ProjectImage] {
        confirmedImages + pendingImages + trashedImages.map(\.image)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fixedPrompt, variablePrompt, createdAt, updatedAt, pendingImage, pendingImages, confirmedImages, trashedImages, deletedAt
    }
}

extension SimpleProject {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fixedPrompt = try container.decode(String.self, forKey: .fixedPrompt)
        variablePrompt = try container.decode(String.self, forKey: .variablePrompt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let images = try container.decodeIfPresent([ProjectImage].self, forKey: .pendingImages) {
            pendingImages = images
        } else {
            pendingImages = try container.decodeIfPresent(ProjectImage.self, forKey: .pendingImage).map { [$0] } ?? []
        }
        confirmedImages = try container.decode([ProjectImage].self, forKey: .confirmedImages)
        // Projects created before the trash feature have no such key.
        trashedImages = try container.decodeIfPresent([TrashedProjectImage].self, forKey: .trashedImages) ?? []
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(fixedPrompt, forKey: .fixedPrompt)
        try container.encode(variablePrompt, forKey: .variablePrompt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(pendingImages, forKey: .pendingImages)
        try container.encode(confirmedImages, forKey: .confirmedImages)
        try container.encode(trashedImages, forKey: .trashedImages)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

/// Local project state is published only after the corresponding atomic metadata write succeeds.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [SimpleProject] = []
    @Published private(set) var errorMessage: String?
    var activeProjects: [SimpleProject] { projects.filter { $0.deletedAt == nil } }
    var deletedProjects: [SimpleProject] {
        projects.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
    }
    let rootURL: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        rootURL = (root ?? support.appendingPathComponent("YingGao/Projects", isDirectory: true)).standardizedFileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load() throws {
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let folders = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            var loaded: [SimpleProject] = []
            var warnings: [String] = []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                do {
                    let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        warnings.append("已跳过异常项目目录 \(id.uuidString.prefix(8))。")
                        continue
                    }
                    let primary = folder.appendingPathComponent("project.json")
                    let backup = folder.appendingPathComponent("project.backup.json")
                    let project: SimpleProject
                    do {
                        project = try decodeProject(at: primary, expectedID: id)
                    } catch {
                        let recovered = try decodeProject(at: backup, expectedID: id)
                        // Keep the broken primary for inspection before restoring a usable copy.
                        if fm.fileExists(atPath: primary.path) {
                            let preserved = folder.appendingPathComponent("project.corrupt-\(UUID().uuidString).json")
                            try fm.copyItem(at: primary, to: preserved)
                        }
                        try encoder.encode(recovered).write(to: primary, options: .atomic)
                        project = recovered
                        warnings.append("“\(recovered.name)”的项目记录异常，已从备份恢复；异常文件保留在项目文件夹。")
                    }
                    loaded.append(project)
                    for asset in project.allImages {
                        let image = imageURL(projectID: id, image: asset)
                        if !fm.fileExists(atPath: image.path) {
                            warnings.append("“\(project.name)”有图片文件缺失，已保留记录，请检查项目文件夹。")
                            break
                        }
                    }
                } catch {
                    warnings.append("项目 \(id.uuidString.prefix(8)) 无法读取，文件已保留，其他项目仍可使用。")
                }
            }
            projects = loaded.sorted { $0.updatedAt > $1.updatedAt }
            errorMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        } catch {
            errorMessage = "无法读取项目目录：\(error.localizedDescription)"
            throw error
        }
    }

    @discardableResult
    func create(name: String) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw report(StoreError.emptyName) }
        guard trimmed.count <= 120 else { throw report(StoreError.longName) }
        let now = Date()
        let project = SimpleProject(id: UUID(), name: trimmed, fixedPrompt: "", variablePrompt: "", createdAt: now, updatedAt: now, pendingImages: [], confirmedImages: [])
        do {
            try persist(project)
            projects.insert(project, at: 0)
            return project.id
        } catch { throw report(error) }
    }

    func updatePrompts(projectID: UUID, fixed: String, variable: String) throws {
        let index = try activeProjectIndex(projectID)
        guard projects[index].fixedPrompt != fixed || projects[index].variablePrompt != variable else { return }
        var updated = projects[index]
        updated.fixedPrompt = fixed
        updated.variablePrompt = variable
        updated.updatedAt = Date()
        do {
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    @discardableResult
    func stageImage(projectID: UUID, source: URL, fixed: String, variable: String, threadID: String?, turnID: String?, appendToPending: Bool = false) throws -> ProjectImage {
        let index = try activeProjectIndex(projectID)
        guard !appendToPending || projects[index].pendingImages.count < 3 else { throw report(StoreError.pendingBatchFull) }
        var copied: URL?
        do {
            let data = try validatedImageBytes(at: source)
            let ext = data.extensionName
            let id = UUID()
            let asset = ProjectImage(id: id, filename: "\(id.uuidString).\(ext)", fixedPrompt: fixed, variablePrompt: variable, createdAt: Date(), threadID: threadID, turnID: turnID)
            let folder = try ensureProjectFolder(projectID)
            let imagePath = folder.appendingPathComponent("assets", isDirectory: true).appendingPathComponent(asset.filename)
            // UUID filenames never overwrite another candidate or a confirmed original.
            guard !fm.fileExists(atPath: imagePath.path) else { throw StoreError.assetCollision }
            try data.bytes.write(to: imagePath, options: .atomic)
            copied = imagePath
            var updated = projects[index]
            if appendToPending {
                updated.pendingImages.append(asset)
            } else {
                // A new successful generation supersedes old candidates without deleting them.
                let replacedAt = Date()
                updated.trashedImages.append(contentsOf: updated.pendingImages.map { TrashedProjectImage(image: $0, deletedAt: replacedAt) })
                updated.pendingImages = [asset]
            }
            updated.updatedAt = Date()
            // Prompt edits made while image generation was running remain untouched.
            try persist(updated)
            projects[index] = updated
            return asset
        } catch {
            if let copied { try? fm.removeItem(at: copied) }
            throw report(error)
        }
    }

    func confirmImage(projectID: UUID, imageID: UUID) throws {
        let index = try activeProjectIndex(projectID)
        if projects[index].confirmedImages.contains(where: { $0.id == imageID }) { return }
        guard let pending = projects[index].pendingImages.first(where: { $0.id == imageID }) else { throw report(StoreError.pendingMismatch) }
        do {
            // Validate the saved bytes again; metadata alone is not proof that an image exists.
            _ = try validatedImageBytes(at: imageURL(projectID: projectID, image: pending))
            var updated = projects[index]
            updated.confirmedImages.append(pending)
            let selectedAt = Date()
            updated.trashedImages.append(contentsOf: updated.pendingImages.filter { $0.id != imageID }.map { TrashedProjectImage(image: $0, deletedAt: selectedAt) })
            updated.pendingImages = []
            updated.updatedAt = Date()
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    func moveImageToTrash(projectID: UUID, imageID: UUID) throws {
        let index = try activeProjectIndex(projectID)
        if projects[index].trashedImages.contains(where: { $0.id == imageID }) { return }
        guard let imageIndex = projects[index].confirmedImages.firstIndex(where: { $0.id == imageID }) else {
            throw report(StoreError.confirmedImageMissing)
        }
        var updated = projects[index]
        let image = updated.confirmedImages.remove(at: imageIndex)
        updated.trashedImages.append(TrashedProjectImage(image: image, deletedAt: Date()))
        updated.updatedAt = Date()
        do {
            // Only metadata changes: the original file remains at its existing asset path.
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    func restoreImage(projectID: UUID, imageID: UUID) throws {
        let index = try activeProjectIndex(projectID)
        if projects[index].confirmedImages.contains(where: { $0.id == imageID }) { return }
        guard let trashIndex = projects[index].trashedImages.firstIndex(where: { $0.id == imageID }) else {
            throw report(StoreError.trashedImageMissing)
        }
        do {
            let image = projects[index].trashedImages[trashIndex].image
            _ = try validatedImageBytes(at: imageURL(projectID: projectID, image: image))
            var updated = projects[index]
            updated.trashedImages.remove(at: trashIndex)
            updated.confirmedImages.append(image)
            updated.updatedAt = Date()
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    func imageURL(projectID: UUID, image: ProjectImage) -> URL {
        let folder = projectFolder(projectID).appendingPathComponent("assets", isDirectory: true)
        guard Self.safeFilename(image.filename) else { return folder.appendingPathComponent("invalid-image") }
        let url = folder.appendingPathComponent(image.filename)
        guard assetPathIsSafe(url, projectID: projectID) else { return rootURL.appendingPathComponent("invalid-image") }
        return url
    }

    func projectFolder(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func clearError() { errorMessage = nil }

    func reorderConfirmedImages(projectID: UUID, orderedIDs: [UUID]) throws {
        let index = try activeProjectIndex(projectID)
        let current = projects[index].confirmedImages
        guard orderedIDs.count == current.count, Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(current.map(\.id)) else { throw report(StoreError.invalidImageOrder) }
        guard orderedIDs != current.map(\.id) else { return }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var updated = projects[index]
        updated.confirmedImages = orderedIDs.compactMap { byID[$0] }
        updated.updatedAt = Date()
        do {
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    func moveProjectToTrash(projectID: UUID) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw report(StoreError.projectMissing) }
        guard projects[index].deletedAt == nil else { return }
        var updated = projects[index]
        updated.deletedAt = Date()
        updated.updatedAt = Date()
        do {
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    func restoreProject(projectID: UUID) throws {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw report(StoreError.projectMissing) }
        guard projects[index].deletedAt != nil else { return }
        var updated = projects[index]
        updated.deletedAt = nil
        updated.updatedAt = Date()
        do {
            try persist(updated)
            projects[index] = updated
        } catch { throw report(error) }
    }

    private func activeProjectIndex(_ projectID: UUID) throws -> Int {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw report(StoreError.projectMissing) }
        guard projects[index].deletedAt == nil else { throw report(StoreError.projectDeleted) }
        return index
    }

    private func report(_ error: Error) -> Error {
        errorMessage = error.localizedDescription
        return error
    }

    private func decodeProject(at url: URL, expectedID: UUID) throws -> SimpleProject {
        guard isContained(url) else { throw StoreError.unsafePath }
        let project = try decoder.decode(SimpleProject.self, from: Data(contentsOf: url))
        guard project.id == expectedID,
              !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.pendingImages.count <= 3,
              Set(project.allImages.map(\.id)).count == project.allImages.count else { throw StoreError.invalidRecord }
        for image in project.allImages {
            guard Self.safeFilename(image.filename), image.filename.hasPrefix(image.id.uuidString + ".") else { throw StoreError.unsafePath }
            let asset = projectFolder(project.id).appendingPathComponent("assets", isDirectory: true).appendingPathComponent(image.filename)
            guard assetPathIsSafe(asset, projectID: project.id) else { throw StoreError.unsafePath }
        }
        return project
    }

    private func ensureProjectFolder(_ id: UUID) throws -> URL {
        let folder = projectFolder(id)
        let assets = folder.appendingPathComponent("assets", isDirectory: true)
        guard isContained(folder), isContained(assets), !isSymbolicLink(folder), !isSymbolicLink(assets) else { throw StoreError.unsafePath }
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        return folder
    }

    private func persist(_ project: SimpleProject) throws {
        let folder = try ensureProjectFolder(project.id)
        let primary = folder.appendingPathComponent("project.json")
        let backup = folder.appendingPathComponent("project.backup.json")
        guard isContained(primary), isContained(backup), !isSymbolicLink(primary), !isSymbolicLink(backup) else { throw StoreError.unsafePath }
        let encoded = try encoder.encode(project)
        if fm.fileExists(atPath: primary.path) {
            // Never replace the only usable backup with corrupted metadata.
            _ = try decodeProject(at: primary, expectedID: project.id)
            let existing = try Data(contentsOf: primary)
            try existing.write(to: backup, options: .atomic)
        }
        try encoded.write(to: primary, options: .atomic)
    }

    private func isContained(_ url: URL) -> Bool {
        let base = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func assetPathIsSafe(_ url: URL, projectID: UUID) -> Bool {
        let project = projectFolder(projectID)
        let assets = project.appendingPathComponent("assets", isDirectory: true)
        guard !isSymbolicLink(project), !isSymbolicLink(assets), isContained(assets) else { return false }
        let scope = assets.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(scope)
    }

    private static func safeFilename(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && ["png", "jpg", "webp", "heic", "tiff", "gif"].contains(String(parts[1]))
    }

    private func validatedImageBytes(at url: URL) throws -> (bytes: Data, extensionName: String) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 200 * 1024 * 1024 else { throw StoreError.invalidImage }
        let bytes = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768, Int64(width) * Int64(height) <= 100_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let rawType = CGImageSourceGetType(source) as String?, let type = UTType(rawType) else { throw StoreError.invalidImage }
        let ext: String
        switch type {
        case .png: ext = "png"
        case .jpeg: ext = "jpg"
        case .tiff: ext = "tiff"
        case .gif: ext = "gif"
        case .heic: ext = "heic"
        case .webP: ext = "webp"
        default: throw StoreError.invalidImage
        }
        return (bytes, ext)
    }

    enum StoreError: LocalizedError {
        case emptyName, longName, projectMissing, projectDeleted, pendingMismatch, pendingBatchFull, confirmedImageMissing, trashedImageMissing, invalidImage, unsafePath, invalidRecord, assetCollision, invalidImageOrder
        var errorDescription: String? {
            switch self {
            case .emptyName: return "请输入项目名称。"
            case .longName: return "项目名称请控制在 120 个字以内。"
            case .projectMissing: return "项目不存在，请重新选择项目。"
            case .projectDeleted: return "项目已在垃圾箱中，请先恢复项目后再操作。"
            case .pendingMismatch: return "待确认图片已变化，请重新查看后确认。"
            case .pendingBatchFull: return "本次最多保留三张候选图片，请先选择图片入库或开始新一组生成。"
            case .confirmedImageMissing: return "这张图片不在当前项目的已确认图库中，请重新查看。"
            case .trashedImageMissing: return "这张图片不在当前项目的垃圾箱中，请重新查看。"
            case .invalidImage: return "图片文件无效、损坏或过大，已有图片未改变。"
            case .unsafePath: return "项目路径异常，已停止保存以保护已有文件。"
            case .invalidRecord: return "项目记录无效，请检查备份。"
            case .assetCollision: return "图片文件名冲突，请重试保存。"
            case .invalidImageOrder: return "图片顺序与当前图库不一致，请刷新后重试。"
            }
        }
    }
}
