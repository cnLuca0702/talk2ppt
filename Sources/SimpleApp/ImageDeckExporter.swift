import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum ImageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pptx, pdf
    var id: String { rawValue }
    var title: String { self == .pptx ? "图片型 PowerPoint（.pptx）" : "图片型 PDF（.pdf）" }
    var fileExtension: String { rawValue }
}

struct ImageExportSlide: Sendable {
    let id: UUID
    let imageURL: URL
}

/// Standalone, local export. Call from a background task with a captured gallery order.
enum ImageDeckExporter {
    private static let pageSize = CGSize(width: 960, height: 540)
    private static let slideWidth = 12_192_000
    private static let slideHeight = 6_858_000

    static func export(slides: [ImageExportSlide], format: ImageExportFormat, to destination: URL) throws {
        guard !slides.isEmpty else { throw ExportError.emptyGallery }
        guard destination.isFileURL, destination.pathExtension.lowercased() == format.fileExtension else {
            throw ExportError.invalidDestination
        }
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw ExportError.invalidDestination
        }
        let outputValues = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard outputValues?.isDirectory != true, outputValues?.isSymbolicLink != true else { throw ExportError.invalidDestination }
        guard !slides.contains(where: { sameFile($0.imageURL, destination) }) else { throw ExportError.sourceOverwrite }
        try Task.checkCancellation()

        // Read and validate every input first, so an incomplete project never replaces a valid export.
        let snapshots = try slides.enumerated().map { index, slide in
            try Task.checkCancellation()
            do { return try snapshot(slide.imageURL) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ExportError.invalidImage(index + 1) }
        }
        let temporary = parent.appendingPathComponent(".yinggao-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let completed = temporary.appendingPathComponent("output.\(format.fileExtension)")
        switch format {
        case .pdf: try writePDF(snapshots, to: completed)
        case .pptx: try writePPTX(snapshots, in: temporary, to: completed)
        }
        try Task.checkCancellation()
        guard let size = try completed.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw ExportError.outputFailed
        }
        // Same-volume rename is atomic, including replacement. Do not remove the old export first.
        let result = completed.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw ExportError.saveFailed(Int(errno)) }
    }

    private struct ImageSnapshot {
        let bytes: Data
        let image: CGImage
        let fileExtension: String
        let contentType: String
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        if first.resolvingSymlinksInPath().standardizedFileURL == second.resolvingSymlinksInPath().standardizedFileURL { return true }
        var a = stat(), b = stat()
        let aOK = first.resolvingSymlinksInPath().path.withCString { Darwin.lstat($0, &a) }
        let bOK = second.resolvingSymlinksInPath().path.withCString { Darwin.lstat($0, &b) }
        return aOK == 0 && bOK == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func snapshot(_ url: URL) throws -> ImageSnapshot {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 200 * 1024 * 1024 else { throw ExportError.outputFailed }
        let bytes = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768,
              Int64(width) * Int64(height) <= 100_000_000 else { throw ExportError.outputFailed }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let decoded: CGImage?
        if orientation == 1 {
            decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
            ] as CFDictionary)
        }
        guard let image = decoded else { throw ExportError.outputFailed }
        let sourceType = CGImageSourceGetType(source) as String?
        if orientation == 1 && sourceType == UTType.png.identifier {
            return ImageSnapshot(bytes: bytes, image: image, fileExtension: "png", contentType: "image/png")
        }
        if orientation == 1 && sourceType == UTType.jpeg.identifier {
            return ImageSnapshot(bytes: bytes, image: image, fileExtension: "jpg", contentType: "image/jpeg")
        }
        // Normalize uncommon formats and EXIF orientation for consistent PDF and PowerPoint appearance.
        let normalized = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(normalized, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.outputFailed }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw ExportError.outputFailed }
        return ImageSnapshot(bytes: normalized as Data, image: image, fileExtension: "png", contentType: "image/png")
    }

    private static func fitRect(image: CGImage, width: Double, height: Double) -> CGRect {
        let scale = min(width / Double(image.width), height / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    }

    private static func writePDF(_ images: [ImageSnapshot], to url: URL) throws {
        var page = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &page, [kCGPDFContextCreator: "映稿"] as CFDictionary) else { throw ExportError.outputFailed }
        for snapshot in images {
            do { try Task.checkCancellation() } catch { context.closePDF(); throw error }
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            context.interpolationQuality = .high
            context.draw(snapshot.image, in: fitRect(image: snapshot.image, width: page.width, height: page.height))
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages == images.count else { throw ExportError.outputFailed }
    }

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let slideNamespaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    private static let emptyShapeTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    private static let whiteBackground = "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"

    private static func writePPTX(_ images: [ImageSnapshot], in temporary: URL, to destination: URL) throws {
        let package = temporary.appendingPathComponent("package", isDirectory: true)
        let directories = ["_rels", "ppt/_rels", "ppt/slides/_rels", "ppt/media", "ppt/slideLayouts/_rels", "ppt/slideMasters/_rels", "ppt/theme", "docProps"]
        for path in directories { try FileManager.default.createDirectory(at: package.appendingPathComponent(path), withIntermediateDirectories: true) }
        func write(_ path: String, _ body: String) throws {
            try Data((xmlHeader + body).utf8).write(to: package.appendingPathComponent(path))
        }
        func rels(_ body: String) -> String { "<Relationships xmlns=\"\(relationshipsNamespace)\">\(body)</Relationships>" }
        func relationship(_ id: String, _ type: String, _ target: String) -> String { "<Relationship Id=\"\(id)\" Type=\"\(officeRelationships)\(type)\" Target=\"\(target)\"/>" }

        let imageTypes = Set(images.map(\.fileExtension)).sorted().map { ext in
            "<Default Extension=\"\(ext)\" ContentType=\"\(ext == "jpg" ? "image/jpeg" : "image/png")\"/>"
        }.joined()
        let slideOverrides = images.indices.map { "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined()
        try write("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(imageTypes)<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/><Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>\(slideOverrides)</Types>")
        try write("_rels/.rels", rels(relationship("rId1", "officeDocument", "ppt/presentation.xml") + relationship("rId2", "extended-properties", "docProps/app.xml")))
        try write("docProps/app.xml", "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>映稿</Application><PresentationFormat>On-screen Show (16:9)</PresentationFormat><Slides>\(images.count)</Slides></Properties>")
        let slideIDs = images.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined()
        try write("ppt/presentation.xml", "<p:presentation \(slideNamespaces)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"\(slideWidth)\" cy=\"\(slideHeight)\" type=\"screen16x9\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        let slideRels = images.indices.map { relationship("rId\($0 + 2)", "slide", "slides/slide\($0 + 1).xml") }.joined()
        try write("ppt/_rels/presentation.xml.rels", rels(relationship("rId1", "slideMaster", "slideMasters/slideMaster1.xml") + slideRels))
        try write("ppt/slideLayouts/slideLayout1.xml", "<p:sldLayout \(slideNamespaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(emptyShapeTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try write("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels(relationship("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")))
        try write("ppt/slideMasters/slideMaster1.xml", "<p:sldMaster \(slideNamespaces)><p:cSld>\(whiteBackground)<p:spTree>\(emptyShapeTree)</p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        try write("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels(relationship("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml") + relationship("rId2", "theme", "../theme/theme1.xml")))
        try write("ppt/theme/theme1.xml", theme)

        for (index, snapshot) in images.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            try snapshot.bytes.write(to: package.appendingPathComponent("ppt/media/image\(number).\(snapshot.fileExtension)"))
            let rectangle = fitRect(image: snapshot.image, width: Double(slideWidth), height: Double(slideHeight))
            let picture = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Image \(number)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(Int(rectangle.minX.rounded()))\" y=\"\(Int(rectangle.minY.rounded()))\"/><a:ext cx=\"\(Int(rectangle.width.rounded()))\" cy=\"\(Int(rectangle.height.rounded()))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            try write("ppt/slides/slide\(number).xml", "<p:sld \(slideNamespaces)><p:cSld>\(whiteBackground)<p:spTree>\(emptyShapeTree)\(picture)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            try write("ppt/slides/_rels/slide\(number).xml.rels", rels(relationship("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml") + relationship("rId2", "image", "../media/image\(number).\(snapshot.fileExtension)")))
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", "-X", destination.path, "."]
        zip.currentDirectoryURL = package
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ExportError.packageFailed }
    }

    private static let theme = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="YingGao"><a:themeElements><a:clrScheme name="YingGao"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="059669"/></a:accent2><a:accent3><a:srgbClr val="D97706"/></a:accent3><a:accent4><a:srgbClr val="7C3AED"/></a:accent4><a:accent5><a:srgbClr val="DB2777"/></a:accent5><a:accent6><a:srgbClr val="0891B2"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="YingGao"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="YingGao"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
    """

    enum ExportError: LocalizedError {
        case emptyGallery, invalidDestination, sourceOverwrite, invalidImage(Int), outputFailed, packageFailed, saveFailed(Int)
        var errorDescription: String? {
            switch self {
            case .emptyGallery: return "项目图库还没有已入库图片，请先确认入库。"
            case .invalidDestination: return "请选择有效的导出位置和对应的文件扩展名。"
            case .sourceOverwrite: return "导出文件不能覆盖项目原始图片，请选择其他位置。"
            case .invalidImage(let page): return "图库第 \(page) 张图片缺失、损坏或过大，导出已停止，原有文件未改变。"
            case .outputFailed: return "无法生成完整的导出文件，原有文件未改变。"
            case .packageFailed: return "PowerPoint 文件打包失败，请检查磁盘空间后重试。"
            case .saveFailed: return "无法保存导出文件，请检查文件夹权限与磁盘空间。原有文件未改变。"
            }
        }
    }
}
