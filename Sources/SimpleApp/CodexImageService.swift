import Foundation
import Combine
import AppKit

struct GeneratedImage {
    let fileURL: URL
    let threadID: String
    let turnID: String
    let revisedPrompt: String?
}

/// A local stdio client. Authentication is owned by the official Codex runtime.
/// This class never opens auth.json, stores tokens, or falls back to Platform APIs.
@MainActor
final class CodexImageService: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "正在连接 ChatGPT…"
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var outputReader: RPCLineReader?
    private var errorDrain: RPCLineReader?
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var connectTask: Task<Void, Never>?
    private var model: String?
    private var mcpOverrides: [String: Any] = [:]
    private var connectionID = UUID()
    private var generationID: UUID?
    private var activeThread: String?
    private var activeTurn: String?
    private var candidate: (URL, String?)?
    private var finalAgentMessage: String?
    private var generationContinuation: CheckedContinuation<GeneratedImage, Error>?
    private var generationTimeout: Task<Void, Never>?
    private var loginID: String?
    private var loginTimeout: Task<Void, Never>?
    private var shuttingDown = false
    private var signingIn = false
    private var cancellationRequested = false

    private static let expectedVersion = "codex-cli 0.163.0"

    func connect() async {
        if let connectTask { await connectTask.value; return }
        guard !isBusy, !signingIn else { return }
        let task = Task { [weak self] in await self?.performConnect() }
        let normalized = Task<Void, Never> { _ = await task.value }
        connectTask = normalized
        await normalized.value
        connectTask = nil
    }

    private func performConnect() async {
        guard !isReady else { return }
        errorMessage = nil
        status = "正在检查 ChatGPT 登录…"
        do {
            if process == nil { try await start() }
            try await refreshAccount()
        } catch {
            isReady = false
            errorMessage = friendly(error)
            status = "连接未就绪"
        }
    }

    func signIn() async {
        guard !isBusy, !signingIn else { return }
        signingIn = true
        defer { signingIn = false }
        errorMessage = nil
        do {
            if let connectTask { await connectTask.value }
            if process == nil { try await start() }
            // Reuse an existing ChatGPT session whenever possible.
            let account = try await rpc("account/read", [:])
            if (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" {
                try await refreshAccount()
                return
            }
            if let old = loginID { _ = try? await rpc("account/login/cancel", ["loginId": old]) }
            let reply = try await rpc("account/login/start", ["type": "chatgpt"])
            guard let urlText = reply["authUrl"] as? String, let url = URL(string: urlText),
                  url.scheme == "https", let id = reply["loginId"] as? String else {
                throw ServiceError.message("登录服务没有返回有效的浏览器授权地址。")
            }
            loginID = id
            guard NSWorkspace.shared.open(url) else {
                _ = try? await rpc("account/login/cancel", ["loginId": id])
                loginID = nil
                throw ServiceError.message("无法打开系统浏览器，请检查默认浏览器后重新登录。")
            }
            status = "请在浏览器完成 Sign in with ChatGPT"
            loginTimeout?.cancel()
            loginTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                guard let self, self.loginID == id else { return }
                _ = try? await self.rpc("account/login/cancel", ["loginId": id])
                self.loginID = nil
                self.status = "登录尚未完成，请重新点击登录"
            }
        } catch {
            isReady = false
            errorMessage = friendly(error)
            status = "登录未完成"
        }
    }

    func generate(prompt: String, workspace: URL) async throws -> GeneratedImage {
        guard !isBusy else { throw ServiceError.message("已有图片正在生成，请等待完成。") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.message("请先填写提示词。") }
        guard isReady, let model else { throw ServiceError.message("请先使用 Sign in with ChatGPT 登录。") }
        guard FileManager.default.fileExists(atPath: workspace.path) else { throw ServiceError.message("项目保存目录不存在，请重新打开项目。") }
        isBusy = true
        errorMessage = nil
        candidate = nil
        finalAgentMessage = nil
        let operation = UUID()
        generationID = operation
        cancellationRequested = false
        status = "正在准备生图…"
        defer {
            if generationID == operation {
                generationID = nil
                activeThread = nil
                activeTurn = nil
                candidate = nil
                finalAgentMessage = nil
                isBusy = false
                generationTimeout?.cancel()
                generationTimeout = nil
            }
        }
        do {
            let account = try await rpc("account/read", [:])
            guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                isReady = false
                throw ServiceError.message("ChatGPT 登录已失效，请重新登录；不会切换到 API 密钥。")
            }
            try checkOperation(operation)
            var config = mcpOverrides
            config["features.shell_tool"] = false
            config["features.apps"] = false
            config["features.multi_agent"] = false
            config["web_search"] = "disabled"
            let thread = try await rpc("thread/start", [
                "model": model,
                "modelProvider": "openai",
                "cwd": workspace.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "config": config,
                "developerInstructions": "You are an image-generation component in a native macOS app. The user supplies a fixed prompt and a variable prompt concatenated as text. Generate exactly one 16:9 complete slide image using the native image generation tool. Do not answer with a prompt, do not request confirmation, and do not use shell, code drawing, SVG, MCP tools, web search, skills, subagents, or external APIs. Preserve the user's wording and constraints. If native image generation is unavailable, report the failure accurately. Return the original generated image; the host app handles saving."
            ])
            try checkOperation(operation)
            guard let tid = (thread["thread"] as? [String: Any])?["id"] as? String else { throw ServiceError.message("生图会话创建失败。") }
            activeThread = tid
            status = "正在生成图片，通常需要几分钟…"
            let result: GeneratedImage = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    generationContinuation = continuation
                    generationTimeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 900_000_000_000) } catch { return }
                        guard let self, self.generationID == operation else { return }
                        await self.interruptCurrent()
                        self.finish(.failure(ServiceError.message("生图等待超过 15 分钟，已请求停止。请检查网络或稍后手动重试；不会自动重复提交。")))
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            let reply = try await self.rpc("turn/start", ["threadId": tid, "input": [["type": "text", "text": prompt]]])
                            guard self.generationID == operation else { return }
                            self.activeTurn = (reply["turn"] as? [String: Any])?["id"] as? String
                            if self.cancellationRequested {
                                await self.interruptCurrent()
                                self.finish(.failure(CancellationError()))
                            }
                        } catch {
                            if self.generationID == operation {
                                // A turn/start transport failure can be ambiguous even without cancel.
                                // Discard this connection before another image can be submitted.
                                self.invalidateTransport()
                                self.finish(.failure(self.cancellationRequested ? CancellationError() : error))
                            }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in await self?.cancel() }
            }
            status = "图片已生成，请检查后确认"
            return result
        } catch {
            if error is CancellationError { errorMessage = nil; status = isReady ? "已停止生成" : "停止结果未确认，请重新连接后检查" }
            else {
                errorMessage = friendly(error); status = "生成未完成"
                // Never leave a known turn running after a local failure.
                await interruptCurrent()
            }
            throw error
        }
    }

    func cancel() async {
        guard isBusy else { return }
        cancellationRequested = true
        status = "正在停止生成…"
        errorMessage = nil
        // During thread/start the guard after its response exits before any turn is sent.
        // During turn/start keep isBusy true until its id is known, then interrupt it.
        // Never clear the thread identity before the server's acknowledgement.
        guard activeTurn != nil else { return }
        await interruptCurrent()
        finish(.failure(CancellationError()))
    }

    func shutdown() {
        shuttingDown = true
        loginTimeout?.cancel()
        generationTimeout?.cancel()
        connectTask?.cancel()
        finish(.failure(CancellationError()))
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        outputReader?.stop(); errorDrain?.stop()
        stdin?.closeFile(); stdin = nil
        process?.terminate(); process = nil
        outputReader = nil; errorDrain = nil
        isReady = false
        isBusy = false
    }

    private func start() async throws {
        shuttingDown = false
        let executable = try Self.locateExecutable()
        let version = try await Self.version(of: executable)
        guard version == Self.expectedVersion else {
            throw ServiceError.message("当前 Codex 版本为 \(version)，此版本应用已验证的运行时是 0.163.0。请使用应用随附运行时或安装匹配版本。")
        }
        let p = Process(), output = Pipe(), input = Pipe(), errors = Pipe()
        p.executableURL = executable
        p.arguments = ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"", "-c", "features.shell_tool=false", "-c", "features.apps=false", "-c", "features.multi_agent=false", "-c", "web_search=\"disabled\""]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.runtimePath(executable)
        p.environment = environment
        // No project config or AGENTS.md is used during the authentication handshake.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardInput = input; p.standardOutput = output; p.standardError = errors
        let token = UUID(); connectionID = token
        let reader = RPCLineReader(handle: output.fileHandleForReading) { [weak self] line in
            guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Task { @MainActor [weak self] in guard self?.connectionID == token else { return }; self?.receive(object) }
        }
        // Drain stderr without persisting inherited configuration, account details or prompts.
        let drain = RPCLineReader(handle: errors.fileHandleForReading) { _ in }
        p.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == token, !self.shuttingDown else { return }
                self.process = nil; self.stdin = nil; self.isReady = false
                let error = ServiceError.message("本地 ChatGPT 连接进程已退出（\(process.terminationStatus)）。请重新连接后手动重试。")
                self.failPending(error)
                self.finish(.failure(error))
                self.errorMessage = error.localizedDescription
                self.status = "连接已断开"
            }
        }
        try p.run()
        process = p; stdin = input.fileHandleForWriting
        outputReader = reader; errorDrain = drain
        reader.start(); drain.start()
        do {
            _ = try await rpc("initialize", ["clientInfo": ["name": "ppt_workflow_simple", "title": "映稿", "version": "0.4.0"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
            // Read only server names, then disable each inherited MCP connection for image turns.
            // The response is never persisted or logged.
            let configuration = try await rpc("config/read", ["includeLayers": false])
            if let config = configuration["config"] as? [String: Any], let servers = config["mcp_servers"] as? [String: Any] {
                mcpOverrides = Dictionary(uniqueKeysWithValues: servers.keys.map { ("mcp_servers.\($0).enabled", false as Any) })
            }
        } catch {
            outputReader?.stop(); errorDrain?.stop()
            process?.terminate(); process = nil; stdin = nil
            throw error
        }
    }

    private func refreshAccount() async throws {
        let response = try await rpc("account/read", [:])
        guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            isReady = false
            status = "请使用 Sign in with ChatGPT 登录"
            model = nil
            return
        }
        let capabilities = try await rpc("modelProvider/capabilities/read", [:])
        guard capabilities["imageGeneration"] as? Bool == true else { throw ServiceError.message("当前 ChatGPT 账号或运行时没有提供原生 image-gen 能力。") }
        let responseModels = try await rpc("model/list", [:])
        let models = responseModels["data"] as? [[String: Any]] ?? []
        guard let selected = models.first(where: { $0["isDefault"] as? Bool == true }) ?? models.first,
              let name = selected["model"] as? String else { throw ServiceError.message("没有取得当前账号可用的模型，请检查网络后重新连接。") }
        model = name
        isReady = true
        status = "ChatGPT 已登录 · image-gen 可用"
        errorMessage = nil
    }

    private func receive(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: ServiceError.message(Self.clean(error["message"] as? String ?? "服务请求失败。")))
            } else { continuation.resume(returning: message["result"] as? [String: Any] ?? [:]) }
            return
        }
        guard let method = message["method"] as? String else { return }
        if let id = message["id"] {
            // No host execution, approval or token refresh implementation is exposed.
            try? send(["id": id, "error": ["code": -32601, "message": "This client supports native image generation only; host actions are disabled."]])
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "account/login/completed" {
            guard loginID == nil || params["loginId"] as? String == loginID else { return }
            loginTimeout?.cancel(); loginTimeout = nil; loginID = nil
            if params["success"] as? Bool == true {
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.refreshAccount() } catch { self.errorMessage = self.friendly(error); self.status = "登录后连接检查失败" }
                }
            } else {
                isReady = false; status = "登录未完成"
                errorMessage = Self.clean(params["error"] as? String ?? "浏览器登录未完成，请重试。")
            }
            return
        }
        guard let thread = activeThread, params["threadId"] as? String == thread else { return }
        if method == "turn/started", let turn = params["turn"] as? [String: Any] {
            activeTurn = turn["id"] as? String
            if cancellationRequested {
                Task { [weak self] in
                    guard let self else { return }
                    await self.interruptCurrent()
                    self.finish(.failure(CancellationError()))
                }
            }
        }
        if method == "item/started", (params["item"] as? [String: Any])?["type"] as? String == "imageGeneration" { status = "image-gen 正在绘制图片…" }
        if method == "item/completed", let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage", let text = item["text"] as? String,
           item["phase"] == nil || item["phase"] as? String == "final_answer" {
            // Retain only the bounded final explanation for no-image failures.
            // Commentary and raw tool payloads are neither persisted nor displayed here.
            finalAgentMessage = Self.clean(text)
        }
        if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "imageGeneration" {
            if item["status"] as? String == "completed", let path = item["savedPath"] as? String, path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path), NSImage(contentsOf: url) != nil {
                    candidate = (url, item["revisedPrompt"] as? String)
                    status = "图片已返回，正在完成本次任务…"
                } else { finish(.failure(ServiceError.message("生图服务返回的原始图片无法读取，请重试。"))) }
            } else {
                let failure = item["failure"] as? [String: Any]
                if failure?["type"] as? String == "usageLimitExceeded" {
                    finish(.failure(ServiceError.message("当前 ChatGPT 的 image-gen 额度已用尽，请等待额度恢复后手动重试。")))
                    return
                }
                finish(.failure(ServiceError.message(Self.clean(failure?["message"] as? String ?? "image-gen 未返回可保存的图片。"))))
            }
        }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            let tid = turn["id"] as? String ?? activeTurn ?? ""
            if let activeTurn, tid != activeTurn { return }
            if cancellationRequested || turn["status"] as? String == "interrupted" { finish(.failure(CancellationError())); return }
            if turn["status"] as? String == "failed" {
                let error = turn["error"] as? [String: Any]
                finish(.failure(ServiceError.message(Self.clean(error?["message"] as? String ?? "生图请求失败，请检查登录、网络或账号额度。"))))
                return
            }
            if let candidate {
                finish(.success(GeneratedImage(fileURL: candidate.0, threadID: thread, turnID: tid, revisedPrompt: candidate.1)))
            } else {
                if let reason = finalAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    finish(.failure(ServiceError.message("本次请求没有生成原始图片。服务说明：\n" + reason)))
                } else {
                    finish(.failure(ServiceError.message("本次请求没有生成原始图片。请检查提示词或稍后重试；未使用其他生图服务。")))
                }
            }
        }
        if method == "error", params["willRetry"] as? Bool != true {
            let error = params["error"] as? [String: Any]
            finish(.failure(ServiceError.message(Self.clean(error?["message"] as? String ?? "生图连接发生错误。"))))
        }
    }

    private func checkOperation(_ operation: UUID) throws {
        if generationID != operation || cancellationRequested || Task.isCancelled { throw CancellationError() }
    }
    @discardableResult private func interruptCurrent() async -> Bool {
        guard let thread = activeThread, let turn = activeTurn else { return false }
        do {
            _ = try await rpc("turn/interrupt", ["threadId": thread, "turnId": turn], timeout: 10)
            return true
        } catch {
            invalidateTransport()
            return false
        }
    }
    private func invalidateTransport() {
        connectionID = UUID()
        outputReader?.stop(); errorDrain?.stop()
        process?.terminate(); process = nil
        stdin?.closeFile(); stdin = nil
        outputReader = nil; errorDrain = nil
        isReady = false; model = nil
        failPending(ServiceError.message("连接状态未确认，已重置连接。请重新连接后手动检查，不会自动重复生图。"))
    }
    private func finish(_ result: Result<GeneratedImage, Error>) {
        generationTimeout?.cancel(); generationTimeout = nil
        let continuation = generationContinuation
        generationContinuation = nil
        continuation?.resume(with: result)
    }
    private func failPending(_ error: Error) {
        let requests = pending; pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
    }
    private func rpc(_ method: String, _ params: [String: Any], timeout: UInt64 = 90) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw ServiceError.message("本地 ChatGPT 连接不可用，请重新连接。") }
        sequence += 1; let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000) } catch { return }
                guard let self, let pending = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id)
                pending.resume(throwing: ServiceError.message("服务响应超时（\(method)）。请检查网络；不会自动重复提交生图。"))
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); timeouts.removeValue(forKey: id)?.cancel() }
        }
    }
    private func send(_ value: [String: Any]) throws {
        guard let stdin else { throw ServiceError.message("连接尚未建立。") }
        var data = try JSONSerialization.data(withJSONObject: value); data.append(0x0A)
        try stdin.write(contentsOf: data)
    }
    private func friendly(_ error: Error) -> String {
        error is CancellationError ? "已停止生成。" : Self.clean(error.localizedDescription)
    }
    private static func clean(_ value: String) -> String {
        // Error strings are bounded and redact obvious credential-shaped material.
        var text = String(value.prefix(1200))
        for pattern in ["(?i)(bearer\\s+)[A-Za-z0-9._-]+", "sk-[A-Za-z0-9_-]+", "data:image/[^;]+;base64,[A-Za-z0-9+/=]+",
                        "(?i)(?:access_token|refresh_token|id_token|api_key|authorization)[\\\"'\\s]*[:=][\\\"'\\s]*[^\\s,;\\\"'&]+",
                        "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"] {
            if let re = try? NSRegularExpression(pattern: pattern) { text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]") }
        }
        return text
    }
    static func locateExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["PPT_WORKFLOW_CODEX_PATH"] { paths.append(override) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("codex").path { paths.append(bundled) }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
        if let path = ProcessInfo.processInfo.environment["PATH"] { paths += path.split(separator: ":").map { String($0) + "/codex" } }
        guard let found = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ServiceError.message("未找到 Codex 运行时。请使用包含运行时的应用安装包。") }
        return URL(fileURLWithPath: found)
    }
    private static func runtimePath(_ executable: URL) -> String {
        [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
    }
    private static func version(of executable: URL) async throws -> String {
        let environment = ["PATH": runtimePath(executable)]
        return try await Task.detached {
            let p = Process(), output = Pipe()
            p.executableURL = executable; p.arguments = ["--version"]; p.environment = environment
            p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ServiceError.message("无法启动 Codex 运行时。") }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        }.value
    }
}

private enum ServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Stream framing lives on one queue. No closure captures an unsynchronized Data buffer.
private final class RPCLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let receive: (String) -> Void
    private let queue = DispatchQueue(label: "ppt-workflow.rpc-reader", qos: .utility)
    private var buffer = Data()
    init(handle: FileHandle, receive: @escaping (String) -> Void) { self.handle = handle; self.receive = receive }
    func start() {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.buffer.append(chunk)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let data = self.buffer[..<newline]; self.buffer.removeSubrange(...newline)
                    if let line = String(data: data, encoding: .utf8) { self.receive(line) }
                }
            }
        }
    }
    func stop() { handle.readabilityHandler = nil }
}
