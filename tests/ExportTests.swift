import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct ExportTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("YingGaoExportTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            precondition(value(), description)
            count += 1
            print("PASS \(description)")
        }
        func expectError(_ description: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected failure: \(description)") }
            catch { count += 1; print("PASS \(description)") }
        }
        func fixture(_ name: String, width: Int, height: Int, color: CGColor, type: UTType = .png, orientation: Int = 1) throws -> URL {
            let url = root.appendingPathComponent(name)
            let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(color)
            canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let output = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, canvas.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { fatalError("fixture failure") }
            return url
        }
        func unzip(_ archive: URL, into target: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", archive.path, "-d", target.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            precondition(p.terminationStatus == 0, "zip is corrupt")
        }
        func xml(_ root: URL, _ path: String) throws -> XMLDocument {
            try XMLDocument(data: Data(contentsOf: root.appendingPathComponent(path)), options: [])
        }
        func nodeString(_ document: XMLDocument, _ xpath: String) throws -> String {
            try document.nodes(forXPath: xpath).first?.stringValue ?? ""
        }
        func pixel(_ page: CGPDFPage, _ x: Int, _ y: Int) -> [Int] {
            let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
            context.drawPDFPage(page)
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            let offset = (y * 960 + x) * 4
            return [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
        }
        func near(_ actual: [Int], _ expected: [Int]) -> Bool {
            // Device RGB -> PDF color management may change channels slightly.
            zip(actual, expected).allSatisfy { abs($0 - $1) < 80 }
        }
        let red = try fixture("wide.png", width: 160, height: 90, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let green = try fixture("square.png", width: 90, height: 90, color: CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let blue = try fixture("portrait.png", width: 60, height: 120, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        // Non-creation order proves export follows the supplied gallery sequence.
        let sources = [blue, red, green]
        let slides = sources.map { ImageExportSlide(id: UUID(), imageURL: $0) }
        let pdf = root.appendingPathComponent("ordered.pdf"), pptx = root.appendingPathComponent("ordered.pptx")
        try ImageDeckExporter.export(slides: slides, format: .pdf, to: pdf)
        try ImageDeckExporter.export(slides: slides, format: .pptx, to: pptx)
        let document = CGPDFDocument(pdf as CFURL)!
        check(document.numberOfPages == 3, "PDF has one page per gallery image")
        check((1...3).allSatisfy { document.page(at: $0)!.getBoxRect(.mediaBox) == CGRect(x: 0, y: 0, width: 960, height: 540) }, "every PDF page is 16:9")
        check(near(pixel(document.page(at: 1)!, 480, 270), [0, 0, 255]), "PDF first page follows portrait blue input")
        check(near(pixel(document.page(at: 2)!, 480, 270), [255, 0, 0]), "PDF second page follows wide red input")
        check(near(pixel(document.page(at: 3)!, 480, 270), [0, 255, 0]), "PDF third page follows square green input")
        check(near(pixel(document.page(at: 1)!, 100, 270), [255, 255, 255]) && near(pixel(document.page(at: 1)!, 346, 270), [0, 0, 255]), "PDF portrait image is centered with white side margins")
        check(near(pixel(document.page(at: 2)!, 10, 10), [255, 0, 0]), "PDF 16:9 image fills the page")
        check(near(pixel(document.page(at: 3)!, 100, 270), [255, 255, 255]) && near(pixel(document.page(at: 3)!, 211, 270), [0, 255, 0]), "PDF square image keeps its aspect ratio")

        let unpacked = root.appendingPathComponent("unpacked")
        try unzip(pptx, into: unpacked)
        let presentation = try xml(unpacked, "ppt/presentation.xml")
        let slideCount = try presentation.nodes(forXPath: "//*[local-name()='sldId']").count
        check(slideCount == 3, "PowerPoint has one slide per gallery image")
        let width = try nodeString(presentation, "//*[local-name()='sldSz']/@cx")
        let height = try nodeString(presentation, "//*[local-name()='sldSz']/@cy")
        check(width == "12192000" && height == "6858000", "PowerPoint slide dimensions are 16:9")
        for index in 0..<3 {
            let embedded = try Data(contentsOf: unpacked.appendingPathComponent("ppt/media/image\(index + 1).png"))
            let original = try Data(contentsOf: sources[index])
            check(embedded == original, "PowerPoint media \(index + 1) retains input bytes and order")
            let slide = try xml(unpacked, "ppt/slides/slide\(index + 1).xml")
            let pictures = try slide.nodes(forXPath: "//*[local-name()='pic']").count
            check(pictures == 1, "PowerPoint slide \(index + 1) contains exactly one image")
            let rel = try xml(unpacked, "ppt/slides/_rels/slide\(index + 1).xml.rels")
            let imageTarget = try nodeString(rel, "//*[local-name()='Relationship' and @Id='rId2']/@Target")
            check(imageTarget == "../media/image\(index + 1).png", "PowerPoint slide \(index + 1) points to correct media")
        }
        let firstSlide = try xml(unpacked, "ppt/slides/slide1.xml")
        let firstX = try nodeString(firstSlide, "//*[local-name()='pic']/*[local-name()='spPr']/*[local-name()='xfrm']/*[local-name()='off']/@x")
        let firstWidth = try nodeString(firstSlide, "//*[local-name()='pic']/*[local-name()='spPr']/*[local-name()='xfrm']/*[local-name()='ext']/@cx")
        check(firstX == "4381500" && firstWidth == "3429000", "PowerPoint portrait geometry uses aspect-fit with centered margins")
        let squareSlide = try xml(unpacked, "ppt/slides/slide3.xml")
        let squareWidth = try nodeString(squareSlide, "//*[local-name()='pic']/*[local-name()='spPr']/*[local-name()='xfrm']/*[local-name()='ext']/@cx")
        let squareHeight = try nodeString(squareSlide, "//*[local-name()='pic']/*[local-name()='spPr']/*[local-name()='xfrm']/*[local-name()='ext']/@cy")
        check(squareWidth == squareHeight, "PowerPoint square image stays square")
        let enumeration = fm.enumerator(at: unpacked, includingPropertiesForKeys: nil)!
        var parsedCount = 0
        while let url = enumeration.nextObject() as? URL {
            if ["xml", "rels"].contains(url.pathExtension) { _ = try XMLDocument(data: Data(contentsOf: url)); parsedCount += 1 }
        }
        check(parsedCount >= 14, "all PowerPoint package XML and relationships are well formed")

        let old = Data("existing export sentinel".utf8)
        try old.write(to: pdf)
        expectError("empty export is rejected") { try ImageDeckExporter.export(slides: [], format: .pdf, to: pdf) }
        check((try? Data(contentsOf: pdf)) == old, "empty export preserves existing destination")
        let missing = ImageExportSlide(id: UUID(), imageURL: root.appendingPathComponent("missing.png"))
        expectError("missing image is rejected before output") { try ImageDeckExporter.export(slides: [slides[0], missing], format: .pdf, to: pdf) }
        check((try? Data(contentsOf: pdf)) == old, "missing image preserves existing destination")
        let corrupt = root.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        expectError("corrupt image is rejected") { try ImageDeckExporter.export(slides: [ImageExportSlide(id: UUID(), imageURL: corrupt)], format: .pdf, to: pdf) }
        check((try? Data(contentsOf: pdf)) == old, "corrupt image preserves existing destination")
        expectError("format mismatch is rejected") { try ImageDeckExporter.export(slides: slides, format: .pptx, to: pdf) }
        let linked = root.appendingPathComponent("source-hardlink.pdf")
        try fm.linkItem(at: red, to: linked)
        expectError("hardlinked source cannot be overwritten") { try ImageDeckExporter.export(slides: slides, format: .pdf, to: linked) }
        let symlink = root.appendingPathComponent("linked.pdf")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: pdf)
        expectError("symlink export destination is rejected") { try ImageDeckExporter.export(slides: slides, format: .pdf, to: symlink) }
        let blocked = root.appendingPathComponent("directory.pdf")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: false)
        expectError("directory export destination is rejected") { try ImageDeckExporter.export(slides: slides, format: .pdf, to: blocked) }
        try ImageDeckExporter.export(slides: [slides[1]], format: .pdf, to: pdf)
        check(CGPDFDocument(pdf as CFURL)?.numberOfPages == 1, "successful export atomically replaces existing destination")
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".yinggao-export-") }
        check(leftovers.isEmpty, "export leaves no partial staging folders")

        let rotated = try fixture("rotated.jpg", width: 120, height: 60, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1), type: .jpeg, orientation: 6)
        let rotatedDeck = root.appendingPathComponent("rotated.pptx")
        try ImageDeckExporter.export(slides: [ImageExportSlide(id: UUID(), imageURL: rotated)], format: .pptx, to: rotatedDeck)
        let rotatedUnpacked = root.appendingPathComponent("rotated-unpacked")
        try unzip(rotatedDeck, into: rotatedUnpacked)
        let rotatedImage = CGImageSourceCreateWithURL(rotatedUnpacked.appendingPathComponent("ppt/media/image1.png") as CFURL, nil)!
        let dimensions = CGImageSourceCopyPropertiesAtIndex(rotatedImage, 0, nil)! as NSDictionary
        check(dimensions[kCGImagePropertyPixelWidth] as? Int == 60 && dimensions[kCGImagePropertyPixelHeight] as? Int == 120, "EXIF orientation normalized consistently for exported images")

        // Optional retained artifacts allow a real native viewer check without using user project data.
        if let retained = ProcessInfo.processInfo.environment["YINGGAO_EXPORT_TEST_OUTPUT"] {
            let folder = URL(fileURLWithPath: retained)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try ImageDeckExporter.export(slides: slides, format: .pdf, to: folder.appendingPathComponent("export-fixture.pdf"))
            try ImageDeckExporter.export(slides: slides, format: .pptx, to: folder.appendingPathComponent("export-fixture.pptx"))
        }
        print("\(count) EXPORT CHECKS PASSED")
    }
}
