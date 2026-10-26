import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Compile with ProjectStore.swift. This tool only writes to a fresh temporary directory.
/// The generated pictures are explicitly marked synthetic UI fixtures, not AI outputs.
@main
struct PrepareUIFixture {
    @MainActor static func main() throws {
        if CommandLine.arguments.dropFirst().contains("--help") {
            print("Build: xcrun swiftc -parse-as-library Sources/SimpleApp/ProjectStore.swift scripts/prepare-ui-fixture.swift -o .build/prepare-ui-fixture")
            print("Run: .build/prepare-ui-fixture")
            print("Creates a new temporary fixture; prints JSON including projectsRoot. No app or AI runtime is launched.")
            return
        }
        guard CommandLine.arguments.count == 1 else { throw FixtureError.arguments }

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("YingGaoUIFixture-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = base.appendingPathComponent("Projects", isDirectory: true)
        let sourceRoot = base.appendingPathComponent("source-images", isDirectory: true)
        // Do not accept a caller-supplied output path: accidental real-project writes are impossible.
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let store = ProjectStore(root: projectsRoot)
        try store.load()
        let emptyProjectID = try store.create(name: "UI 测试 · 空白项目")
        let projectID = try store.create(name: "UI 测试 · 排序与预览")
        let fixed = "这是离线界面测试项目，图片为本地合成的测试夹具，不代表 AI 生图结果。"
        let variable = "请用于验证预览清空、放大、拖拽排序和候选图片确认入库。"
        try store.updatePrompts(projectID: projectID, fixed: fixed, variable: variable)

        let definitions: [(name: String, color: (CGFloat, CGFloat, CGFloat), label: String)] = [
            ("01-red", (0.72, 0.10, 0.15), "RED / 01"),
            ("02-blue", (0.06, 0.29, 0.76), "BLUE / 02"),
            ("03-green", (0.02, 0.48, 0.26), "GREEN / 03"),
            ("04-pending-amber", (0.70, 0.39, 0.01), "PENDING / 04")
        ]
        var gallery: [[String: Any]] = []
        var pending: [String: Any] = [:]
        for (index, definition) in definitions.enumerated() {
            let source = sourceRoot.appendingPathComponent(definition.name + ".png")
            try drawFixture(index: index + 1, label: definition.label, color: definition.color, to: source)
            let record = try store.stageImage(
                projectID: projectID, source: source, fixed: fixed,
                variable: "离线合成图片：\(definition.label)", threadID: nil, turnID: nil
            )
            let savedURL = store.imageURL(projectID: projectID, image: record)
            let bytes = try Data(contentsOf: source)
            guard try Data(contentsOf: savedURL) == bytes else { throw FixtureError.copyMismatch }
            let details: [String: Any] = [
                "imageID": record.id.uuidString, "label": definition.label,
                "sourcePath": source.path, "assetPath": savedURL.path,
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "width": 1280, "height": 720
            ]
            if index < 3 {
                try store.confirmImage(projectID: projectID, imageID: record.id)
                gallery.append(details)
            } else { pending = details }
        }

        // Verify using the same decoder as the app, including the pending record and empty project.
        let reloaded = ProjectStore(root: projectsRoot)
        try reloaded.load()
        guard reloaded.errorMessage == nil,
              let project = reloaded.activeProjects.first(where: { $0.id == projectID }),
              project.confirmedImages.count == 3, project.pendingImages.count == 1,
              reloaded.activeProjects.first(where: { $0.id == emptyProjectID })?.allImages.isEmpty == true else {
            throw FixtureError.reloadFailed
        }

        let manifest: [String: Any] = [
            "kind": "isolated-offline-ui-fixture",
            "warning": "All four images are locally synthesized test fixtures. No AI request, account read, or app launch was performed.",
            "fixtureRoot": base.path,
            "projectsRoot": projectsRoot.path,
            "mainProjectID": projectID.uuidString,
            "emptyProjectID": emptyProjectID.uuidString,
            "gallery": gallery,
            "pendingCandidate": pending,
            "launchArgumentsForUITestingBuild": ["--ui-test-projects", projectsRoot.path],
            "checks": ["isolatedTemporaryRoot": true, "galleryCount": 3, "pendingCount": 1, "reloadPassed": true],
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: base.appendingPathComponent("fixture.json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
    }

    private static func drawFixture(index: Int, label: String, color: (CGFloat, CGFloat, CGFloat), to url: URL) throws {
        let width = 1280, height = 720
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError.drawingFailed
        }
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 0.16))
        for tick in 0..<index {
            context.fill(CGRect(x: 66 + tick * 90, y: 530, width: 62, height: 62))
        }
        drawText("\(index)", size: 280, color: CGColor(gray: 1, alpha: 1), at: CGPoint(x: 65, y: 205), in: context)
        drawText(label, size: 64, color: CGColor(gray: 1, alpha: 1), at: CGPoint(x: 430, y: 340), in: context)
        drawText("1280 x 720  |  16:9", size: 32, color: CGColor(gray: 1, alpha: 0.92), at: CGPoint(x: 435, y: 270), in: context)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
        drawText("LOCAL UI FIXTURE - NO AI REQUEST", size: 34, color: CGColor(gray: 0.12, alpha: 1), at: CGPoint(x: 65, y: 37), in: context)
        // Corner marks make it easy to notice accidental crop/stretch in exports or previews.
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(8)
        context.stroke(CGRect(x: 18, y: 118, width: 1244, height: 584))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError.drawingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.drawingFailed }
    }

    private static func drawText(_ text: String, size: CGFloat, color: CGColor, at point: CGPoint, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private enum FixtureError: LocalizedError {
        case arguments, drawingFailed, copyMismatch, reloadFailed
        var errorDescription: String? {
            switch self {
            case .arguments: return "This script accepts no output path; all fixture data must stay in a new temporary directory. Use --help for instructions."
            case .drawingFailed: return "Unable to write the diagnostic image."
            case .copyMismatch: return "ProjectStore did not retain the fixture image bytes."
            case .reloadFailed: return "The isolated fixture failed ProjectStore reload validation."
            }
        }
    }
}
