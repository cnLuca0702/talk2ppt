import Foundation
import Combine

/// One user action owns one immutable prompt snapshot and one or three independent image turns.
@MainActor
final class GenerationCoordinator: ObservableObject {
    @Published private(set) var activeProjectID: UUID?
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var requestedCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var itemStartedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var status = "等待生成"
    @Published private(set) var latestImageID: UUID?
    @Published private(set) var latestImageProjectID: UUID?
    @Published private(set) var estimatedPerImageSeconds: Double

    private let service: CodexImageService
    private let store: ProjectStore
    private let defaults: UserDefaults
    private var statusSubscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var cancellationRequested = false
    private var succeeded = false
    private var estimateFloor = 0.0
    private static let estimateKey = "YingGao.estimatedImageSeconds"

    init(service: CodexImageService, store: ProjectStore, defaults: UserDefaults = .standard) {
        self.service = service
        self.store = store
        self.defaults = defaults
        let saved = defaults.double(forKey: Self.estimateKey)
        estimatedPerImageSeconds = saved.isFinite && saved > 0 ? min(240, max(30, saved)) : 90
        statusSubscription = service.$status.sink { [weak self] message in
            guard let self, self.isRunning, !self.cancellationRequested else { return }
            self.status = "第 \(min(self.completedCount + 1, self.requestedCount)) / \(self.requestedCount) 张 · \(message)"
        }
    }

    func start(project: SimpleProject, count: Int) {
        // A second click must never add work to an already running batch.
        guard !isRunning, !service.isBusy else { return }
        errorMessage = nil
        guard count == 1 || count == 3 else { failToStart("每次可生成 1 张或 3 张图片。"); return }
        guard service.isReady else { failToStart("请先使用 Sign in with ChatGPT 登录。"); return }
        guard store.projects.contains(where: { $0.id == project.id && $0.deletedAt == nil }) else {
            failToStart("项目已被删除或不存在，请恢复项目后再生成。")
            return
        }
        let fixed = project.fixedPrompt
        let variable = project.variablePrompt
        let prompt = [fixed, variable].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failToStart("请先填写提示词。")
            return
        }
        let projectID = project.id
        let workspace = store.projectFolder(projectID)
        cancellationRequested = false
        succeeded = false
        estimateFloor = 0
        completedCount = 0
        requestedCount = count
        latestImageID = nil
        latestImageProjectID = nil
        startedAt = Date()
        itemStartedAt = nil
        activeProjectID = projectID
        status = "准备生成 \(count) 张图片…"
        isRunning = true

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.itemStartedAt = nil
                self.activeProjectID = nil
                self.isRunning = false
                self.task = nil
            }
            do {
                for index in 0..<count {
                    try self.checkCanContinue(projectID: projectID)
                    let itemStart = Date()
                    self.itemStartedAt = itemStart
                    self.status = "正在生成第 \(index + 1) / \(count) 张图片…"
                    let image = try await self.service.generate(prompt: prompt, workspace: workspace)
                    // A returned result is saved even if Stop was clicked just after the service
                    // completed. Stop prevents subsequent turns; it does not discard finished work.
                    guard self.store.projects.contains(where: { $0.id == projectID && $0.deletedAt == nil }) else {
                        throw CoordinatorError.projectUnavailable
                    }
                    let staged = try self.store.stageImage(
                        projectID: projectID, source: image.fileURL, fixed: fixed, variable: variable,
                        threadID: image.threadID, turnID: image.turnID, appendToPending: index > 0
                    )
                    self.latestImageProjectID = projectID
                    self.latestImageID = staged.id
                    self.completedCount += 1
                    self.recordDuration(Date().timeIntervalSince(itemStart))
                    // Give cancellation and UI input an opportunity between independent requests.
                    await Task.yield()
                }
                self.succeeded = true
                self.status = count == 3 ? "3 张图片已生成，请选择一张确认入库" : "图片已生成，请检查后确认入库"
            } catch is CancellationError {
                self.status = self.completedCount == 0 ? "已停止生成" : "已停止，已保留 \(self.completedCount) 张候选图片"
            } catch {
                let reason = error.localizedDescription
                self.errorMessage = self.completedCount == 0 ? reason : "已保留 \(self.completedCount) 张候选图片，后续生成已停止。\n\(reason)"
                self.status = self.completedCount == 0 ? "生成未完成" : "已完成 \(self.completedCount) / \(count) 张，后续生成未完成"
            }
        }
    }

    func cancel() async {
        guard isRunning else { return }
        cancellationRequested = true
        status = "正在停止生成…"
        let runningTask = task
        await service.cancel()
        await runningTask?.value
    }

    /// This is an estimate, not a server-reported percentage. It cannot reach 100% early.
    func progress(at date: Date) -> Double {
        if succeeded { return 1 }
        guard requestedCount > 0 else { return 0 }
        let elapsed = itemStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        let itemFraction = min(0.9, 1 - exp(-elapsed / max(30, estimatedPerImageSeconds)))
        let estimate = (Double(completedCount) + (isRunning ? itemFraction : 0)) / Double(requestedCount)
        estimateFloor = min(0.95, max(estimateFloor, estimate))
        return estimateFloor
    }

    private func checkCanContinue(projectID: UUID) throws {
        if cancellationRequested || Task.isCancelled { throw CancellationError() }
        guard store.projects.contains(where: { $0.id == projectID && $0.deletedAt == nil }) else {
            throw CoordinatorError.projectUnavailable
        }
    }

    private func failToStart(_ message: String) {
        errorMessage = message
        status = "无法开始生成"
    }

    private func recordDuration(_ duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        let sample = min(240, max(30, duration))
        estimatedPerImageSeconds = min(240, max(30, estimatedPerImageSeconds * 0.75 + sample * 0.25))
        defaults.set(estimatedPerImageSeconds, forKey: Self.estimateKey)
    }

    private enum CoordinatorError: LocalizedError {
        case projectUnavailable
        var errorDescription: String? { "项目已被删除或不存在，本次生成已停止；已生成的原始文件仍由本地运行时保留。" }
    }
}
