import Foundation
import ImageIO
import Darwin

/// Opt-in, one-image smoke test of the real app service and durable project store.
/// This deliberately exercises no UI and never touches the user's normal project directory.
@main
struct LiveSimpleSmoke {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.contains("--live") else {
            print("NOT_RUN: pass --live to use the current ChatGPT account for one real image generation. Set PPT_WORKFLOW_CODEX_PATH to the bundled runtime in the launching environment.")
            return
        }

        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runID = UUID().uuidString
        let runRoot = sourceRoot.appendingPathComponent("validation/simple-app/live-projects/run-\(runID)", isDirectory: true)
        let projectRoot = runRoot.appendingPathComponent("Projects", isDirectory: true)
        let reportURL = runRoot.appendingPathComponent("report.json")
        let service = CodexImageService()
        defer { service.shutdown() }
        var checks: [String: Bool] = [:]
        var report: [String: Any] = [
            "runID": runID,
            "scope": "real-service-and-storage; GUI NOT_RUN",
            "runRoot": runRoot.path,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "status": "RUNNING"
        ]
        func require(_ condition: Bool, _ name: String) throws {
            checks[name] = condition
            if !condition { throw SmokeError.failedCheck(name) }
        }
        func writeReport() throws {
            report["checks"] = checks
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        }
        do {
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
            try writeReport()
            await service.connect()
            try require(service.isReady, "ChatGPT_account_ready")
            // The service itself rejects API-key account types before generation.
            let store = ProjectStore(root: projectRoot)
            try store.load()
            let first = try store.create(name: "自动验收 · 工作流程")
            let fixed = "生成一张完整的16:9横版中文幻灯片。白色背景，蓝色圆角图形，现代中文无衬线字体，简洁清晰。仅使用指定文字，不增加数据、标志或水印。"
            let variable = "大标题为「工作流程」。中间从左到右排列三个步骤：「输入」「生成」「确认」，用细箭头连接。"
            let merged = fixed + "\n\n" + variable
            try store.updatePrompts(projectID: first, fixed: fixed, variable: variable)
            let before = ProjectStore(root: projectRoot)
            try before.load()
            try require(before.projects.first(where: { $0.id == first })?.fixedPrompt == fixed && before.projects.first(where: { $0.id == first })?.variablePrompt == variable, "both_prompts_persisted")
            report["projectID"] = first.uuidString
            report["inputSnapshot"] = ["fixedPrompt": fixed, "variablePrompt": variable, "mergedPrompt": merged]
            try writeReport()

            let generated = try await service.generate(prompt: merged, workspace: store.projectFolder(first))
            try require(FileManager.default.fileExists(atPath: generated.fileURL.path), "native_image_returned")
            // Emulate a newer draft without changing the captured inputs used for the image.
            let nextDraft = "下一张草稿：请保留本页的蓝白风格。"
            try store.updatePrompts(projectID: first, fixed: fixed, variable: nextDraft)
            let staged = try store.stageImage(projectID: first, source: generated.fileURL, fixed: fixed, variable: variable, threadID: generated.threadID, turnID: generated.turnID)
            let pendingStore = ProjectStore(root: projectRoot)
            try pendingStore.load()
            let pendingProject = pendingStore.projects.first(where: { $0.id == first })
            try require(pendingProject?.pendingImage?.id == staged.id, "pending_survives_reload")
            try require(pendingProject?.variablePrompt == nextDraft, "newer_draft_preserved")
            try require(pendingProject?.pendingImage?.fixedPrompt == fixed && pendingProject?.pendingImage?.variablePrompt == variable, "image_input_snapshot_preserved")
            try pendingStore.confirmImage(projectID: first, imageID: staged.id)
            try pendingStore.confirmImage(projectID: first, imageID: staged.id)

            let finalStore = ProjectStore(root: projectRoot)
            try finalStore.load()
            let confirmedProject = finalStore.projects.first(where: { $0.id == first })
            try require(confirmedProject?.confirmedImages.count == 1 && confirmedProject?.confirmedImages.first?.id == staged.id, "confirmed_gallery_survives_reload")
            try require(confirmedProject?.pendingImage == nil, "confirmed_candidate_consumed")
            let imageURL = finalStore.imageURL(projectID: first, image: staged)
            guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw SmokeError.failedCheck("saved_image_decodable") }
            try require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil, "saved_image_decodable")
            try require(width > 0 && height > 0 && abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.03, "landscape_16_9_within_rounding_tolerance")
            let second = try finalStore.create(name: "自动验收 · 空白项目")
            let isolationStore = ProjectStore(root: projectRoot)
            try isolationStore.load()
            let blank = isolationStore.projects.first(where: { $0.id == second })
            try require(blank?.confirmedImages.isEmpty == true && blank?.pendingImage == nil && blank?.fixedPrompt == "" && blank?.variablePrompt == "", "second_project_isolated")
            try require(isolationStore.projects.first(where: { $0.id == first })?.confirmedImages.count == 1, "first_gallery_unchanged")
            report["status"] = "PASS"
            report["secondProjectID"] = second.uuidString
            report["image"] = ["id": staged.id.uuidString, "path": imageURL.path, "width": width, "height": height, "threadID": generated.threadID, "turnID": generated.turnID]
            report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            try writeReport()
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        } catch {
            report["status"] = "FAIL"
            report["error"] = (error as? SmokeError)?.localizedDescription ?? "Live service or project storage failed; inspect the app's own status and retained test project."
            report["serviceStatus"] = service.status
            report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            try? writeReport()
            print(String(data: (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "Live smoke failed.")
            exit(1)
        }
    }

    enum SmokeError: LocalizedError {
        case failedCheck(String)
        var errorDescription: String? {
            switch self { case .failedCheck(let name): return "Acceptance check failed: \(name)" }
        }
    }
}
