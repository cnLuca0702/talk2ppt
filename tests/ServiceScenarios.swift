import Foundation
@main struct ServiceScenarios {
    @MainActor static func main() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingGaoServiceTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let trace = temporary.appendingPathComponent("service.log")
        let fixture = try SyntheticImageFixture.write(to: temporary.appendingPathComponent("fixture.png"))
        setenv("PPT_WORKFLOW_CODEX_PATH", cwd.appendingPathComponent("tests/ServiceFakeCodex.py").path, 1)
        setenv("PPT_TEST_IMAGE", fixture.path, 1)
        setenv("PPT_TEST_TRACE_PATH", trace.path, 1)
        let service = CodexImageService()
        await service.connect()
        precondition(service.isReady, service.errorMessage ?? "fixture not ready")
        let image = try await service.generate(prompt: "success", workspace: cwd)
        precondition(image.turnID == "turn-test" && FileManager.default.fileExists(atPath: image.fileURL.path))
        print("PASS native image event returns original file")
        do { _ = try await service.generate(prompt: "missing-image", workspace: cwd); fatalError("accepted missing image") }
        catch { precondition(service.errorMessage != nil) }
        print("PASS missing image is an explicit error")
        do { _ = try await service.generate(prompt: "missing-runtime", workspace: cwd); fatalError("accepted missing runtime") }
        catch {
            let message = service.errorMessage ?? ""
            precondition(message.contains("codex-code-mode-host") && message.contains("No such file"), "missing-runtime reason was lost")
            precondition(!message.contains("PRIVATE-TOKEN") && !message.contains("PRIVATE-ACCESS"), "credential-shaped text was exposed")
        }
        print("PASS missing-runtime explanation is retained and credentials redacted")
        let task = Task { try await service.generate(prompt: "cancel-before-turn", workspace: cwd) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await service.cancel()
        precondition(service.isBusy, "must remain busy until in-flight turn ID is reconciled")
        do { _ = try await service.generate(prompt: "duplicate", workspace: cwd); fatalError("duplicate generation allowed") }
        catch { }
        do { _ = try await task.value; fatalError("cancel returned image") }
        catch is CancellationError { }
        precondition(!service.isBusy)
        precondition(service.errorMessage == nil, "intentional cancellation must not raise error alert")
        let events = try String(contentsOf: trace, encoding: .utf8)
        precondition(events.contains("interrupted"), "server was not interrupted after delayed turn ID")
        precondition(events.components(separatedBy: "turn-request").count - 1 == 4, "duplicate turn submitted")
        print("PASS cancellation before turn ID waits, interrupts, prevents duplicate submissions")
        service.shutdown()
        setenv("PPT_TEST_AUTH", "apiKey", 1)
        let api = CodexImageService(); await api.connect()
        precondition(!api.isReady)
        print("PASS API-key identity cannot enable image generation")
        api.shutdown()
        try? FileManager.default.removeItem(at: trace)
    }
}
