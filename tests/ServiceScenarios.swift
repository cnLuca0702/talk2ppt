import Foundation

@main struct ServiceScenarios {
    @MainActor static func main() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("YingGaoServiceTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let trace = temporary.appendingPathComponent("service.log")
        let state = temporary.appendingPathComponent("state.json")
        let fixture = try SyntheticImageFixture.write(to: temporary.appendingPathComponent("fixture.png"))
        let suite = "YingGaoServiceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        setenv("PPT_WORKFLOW_CODEX_PATH", cwd.appendingPathComponent("tests/ServiceFakeCodex.py").path, 1)
        setenv("PPT_TEST_IMAGE", fixture.path, 1)
        setenv("PPT_TEST_TRACE_PATH", trace.path, 1)
        setenv("PPT_TEST_STATE_PATH", state.path, 1)
        defer {
            for key in ["PPT_WORKFLOW_CODEX_PATH", "PPT_TEST_IMAGE", "PPT_TEST_TRACE_PATH", "PPT_TEST_STATE_PATH"] { unsetenv(key) }
        }

        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
            print("PASS \(message)")
        }
        func writeState(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: state, options: .atomic)
        }
        func events() -> [String] {
            ((try? String(contentsOf: trace, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() {
                guard Date() < deadline else { throw TestError.timeout }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let originalPages: [[[String: Any]]] = [
            [
                ["id": "row-default", "model": "test-model", "displayName": "Fixture Default", "description": "Synthetic default model", "isDefault": true, "hidden": false],
                ["id": "row-hidden", "model": "hidden-model", "displayName": "Hidden Fixture", "isDefault": false, "hidden": true]
            ],
            [
                ["id": "row-alternate", "model": "alternate-model", "displayName": "Fixture Alternate", "description": "Synthetic alternate model", "isDefault": false],
                ["id": "different-row-same-model", "model": "test-model", "displayName": "Duplicate Fixture", "isDefault": false]
            ]
        ]
        try writeState(["modelPages": originalPages])
        var service = CodexImageService(defaults: defaults)
        defer { service.shutdown() }
        await service.connect()
        check(service.isReady, "ChatGPT fixture is ready")
        check(service.availableModels.map(\.id) == ["test-model", "alternate-model"], "catalog follows all pages, excludes hidden rows and deduplicates model slugs")
        check(service.selectedModelID == "test-model" && service.selectedModel?.displayName == "Fixture Default", "first connection selects the catalog default")
        check(service.selectedModel?.description == "Synthetic default model", "model description survives catalog decoding")
        check(events().filter { $0.hasPrefix("model-request:") } == ["model-request:0", "model-request:1"], "model discovery uses the returned pagination cursor")
        try service.selectModel("alternate-model")
        check(service.selectedModelID == "alternate-model", "valid catalog slug can be selected")
        do { try service.selectModel("row-default"); fatalError("accepted catalog row ID instead of model slug") }
        catch { check(service.selectedModelID == "alternate-model", "invalid selection leaves the current model intact") }

        let image = try await service.generate(prompt: "success", workspace: cwd)
        check(image.turnID == "turn-test" && FileManager.default.fileExists(atPath: image.fileURL.path), "native image event returns original file")
        check(events().last { $0.hasPrefix("thread-model:") } == "thread-model:alternate-model", "thread/start submits the selected actual model slug")
        do { _ = try await service.generate(prompt: "missing-image", workspace: cwd); fatalError("accepted missing image") }
        catch { check(service.errorMessage != nil, "missing image is an explicit error") }
        do { _ = try await service.generate(prompt: "missing-runtime", workspace: cwd); fatalError("accepted missing runtime") }
        catch {
            let message = service.errorMessage ?? ""
            check(message.contains("codex-code-mode-host") && message.contains("No such file"), "missing-runtime explanation is retained")
            check(!message.contains("PRIVATE-TOKEN") && !message.contains("PRIVATE-ACCESS"), "credential-shaped fixture text is redacted")
        }

        let task = Task { try await service.generate(prompt: "cancel-before-turn", workspace: cwd) }
        try await waitUntil { service.isBusy && events().filter { $0 == "turn-request" }.count == 4 }
        do { try service.selectModel("test-model"); fatalError("changed model while generating") }
        catch { check(service.selectedModelID == "alternate-model", "generation prevents model changes") }
        let discoveryCount = events().filter { $0.hasPrefix("model-request:") }.count
        await service.refreshModels()
        check(events().filter { $0.hasPrefix("model-request:") }.count == discoveryCount, "generation prevents competing catalog refresh requests")
        await service.cancel()
        check(service.isBusy, "cancellation remains busy until the in-flight turn ID is reconciled")
        do { _ = try await service.generate(prompt: "duplicate", workspace: cwd); fatalError("duplicate generation allowed") }
        catch { }
        do { _ = try await task.value; fatalError("cancel returned image") }
        catch is CancellationError { }
        check(!service.isBusy && service.errorMessage == nil, "intentional cancellation finishes without an error alert")
        check(events().contains("interrupted"), "server is interrupted after its delayed turn ID arrives")
        check(events().filter { $0 == "turn-request" }.count == 4, "cancellation prevents duplicate submissions")

        service.shutdown()
        service = CodexImageService(defaults: defaults)
        await service.connect()
        check(service.isReady && service.selectedModelID == "alternate-model", "selection persists across service shutdown and recreation")
        let revisedPages: [[[String: Any]]] = [
            [["id": "new-row-default", "model": "test-model", "displayName": "Fixture Default", "isDefault": true]],
            [["id": "row-new", "model": "new-model", "displayName": "Fixture New", "isDefault": false]]
        ]
        try writeState(["modelPages": revisedPages])
        await service.refreshModels()
        check(service.selectedModelID == "test-model", "a removed model falls back to the current catalog default")
        check(!(service.modelSelectionNotice ?? "").isEmpty, "fallback explains that the previous model is unavailable")
        try service.selectModel("new-model")
        let validCatalog = service.availableModels
        try writeState(["modelPages": originalPages, "modelErrorPage": 1])
        await service.refreshModels()
        check(service.availableModels == validCatalog && service.selectedModelID == "new-model", "partial catalog failure preserves the last valid catalog and selection")
        check(service.isReady && !service.isLoadingModels, "failed catalog refresh leaves an authenticated idle service usable")
        check(service.errorMessage != nil || !(service.modelSelectionNotice ?? "").isEmpty, "catalog refresh failure is surfaced")

        try writeState(["modelPages": revisedPages, "modelDelaySeconds": 0.25])
        let refresh = Task { await service.refreshModels() }
        try await waitUntil { service.isLoadingModels }
        let threadCount = events().filter { $0.hasPrefix("thread-model:") }.count
        do { try service.selectModel("test-model"); fatalError("changed model during refresh") }
        catch { check(service.selectedModelID == "new-model", "catalog refresh prevents model changes") }
        do { _ = try await service.generate(prompt: "refresh-race", workspace: cwd); fatalError("generation competed with catalog refresh") }
        catch { }
        await refresh.value
        check(events().filter { $0.hasPrefix("thread-model:") }.count == threadCount, "catalog refresh prevents a competing generation request")
        check(!service.isLoadingModels && service.selectedModelID == "new-model", "completed refresh releases the selection lock")

        let modelRequestsBeforeShutdown = events().filter { $0.hasPrefix("model-request:") }.count
        try writeState(["modelPages": originalPages, "modelDelaySeconds": 0.4])
        let staleRefresh = Task { await service.refreshModels() }
        try await waitUntil {
            service.isLoadingModels && events().filter { $0.hasPrefix("model-request:") }.count > modelRequestsBeforeShutdown
        }
        service.shutdown()
        check(!service.isReady && service.selectedModelID == nil && !service.isLoadingModels, "shutdown cancels an in-flight model refresh and clears active selection")
        try writeState(["modelPages": revisedPages])
        await service.connect()
        await staleRefresh.value
        check(service.isReady && service.selectedModelID == "new-model", "the same service reconnects with its remembered model after refresh cancellation")
        check(service.availableModels == validCatalog && service.modelSelectionNotice == nil, "a stale refresh cannot overwrite the reconnected catalog or show a false fallback")

        try writeState(["modelPages": revisedPages, "auth": "apiKey"])
        await service.refreshModels()
        check(!service.isReady && service.selectedModelID == nil, "authentication loss during refresh clears ready state and selected model")
        do { try service.selectModel("test-model"); fatalError("selected model without ChatGPT authentication") }
        catch { check(service.selectedModelID == nil, "model selection requires ChatGPT authentication") }
        try writeState(["modelPages": revisedPages])
        await service.connect()
        check(service.isReady && service.selectedModelID == "new-model", "reconnection restores the remembered valid model")
        try writeState(["modelPages": revisedPages, "auth": "apiKey"])
        do { _ = try await service.generate(prompt: "auth-expired", workspace: cwd); fatalError("generated after authentication expired") }
        catch { }
        check(!service.isReady && service.selectedModelID == nil, "generation authentication preflight clears an expired selection")
        check(events().filter { $0.hasPrefix("thread-model:") }.count == threadCount, "expired authentication cannot start a native image thread")

        service.shutdown()
        service = CodexImageService(defaults: defaults)
        await service.connect()
        check(!service.isReady && service.selectedModelID == nil, "API-key identity cannot enable image generation")
        print("\(checks) SERVICE CHECKS PASSED")
    }

    enum TestError: Error { case timeout }
}
