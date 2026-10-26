import Foundation

@main
struct GenerationTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("YingGaoBatchTests-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let fake = temp.appendingPathComponent("fake-codex")
        try fakeSource.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("PPT_WORKFLOW_CODEX_PATH", fake.path, 1)
        let fixture = try SyntheticImageFixture.write(to: temp.appendingPathComponent("fixture.png"))
        setenv("PPT_BATCH_IMAGE", fixture.path, 1)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
            print("PASS \(message)")
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() {
                guard Date() < deadline else { throw TestFailure.timeout }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func trace(_ path: URL) -> [[String: Any]] {
            ((try? String(contentsOf: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }

        for scenario in ["success", "second-fails", "cancel-second", "delete-second", "save-fails", "cancel-immediate"] {
            let run = temp.appendingPathComponent(scenario, isDirectory: true)
            let store = ProjectStore(root: run.appendingPathComponent("projects"))
            try store.load()
            let projectID = try store.create(name: scenario)
            try store.updatePrompts(projectID: projectID, fixed: "固定风格", variable: "本页内容")
            let project = store.projects.first { $0.id == projectID }!
            let traceURL = run.appendingPathComponent("trace.jsonl")
            setenv("PPT_BATCH_SCENARIO", scenario, 1)
            setenv("PPT_BATCH_TRACE", traceURL.path, 1)
            let service = CodexImageService()
            await service.connect()
            check(service.isReady, "\(scenario): ChatGPT fixture is ready")
            let suite = "YingGaoBatchTests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let coordinator = GenerationCoordinator(service: service, store: store, defaults: defaults)
            coordinator.start(project: project, count: 3)
            check(coordinator.isRunning && coordinator.activeProjectID == projectID, "\(scenario): start immediately owns project")
            coordinator.start(project: project, count: 3)

            switch scenario {
            case "success":
                let earlyEstimate = coordinator.progress(at: Date().addingTimeInterval(10_000))
                check(earlyEstimate < 1 && earlyEstimate <= 0.95, "estimate never reaches 100% before completion")
                check(coordinator.progress(at: Date().addingTimeInterval(-10_000)) >= earlyEstimate, "estimate never goes backward")
                try store.updatePrompts(projectID: projectID, fixed: "已编辑风格", variable: "下一页")
            case "cancel-second", "delete-second", "save-fails":
                try await waitUntil { trace(traceURL).filter { $0["type"] as? String == "turn" }.count == 2 }
                check(coordinator.completedCount == 1, "\(scenario): first result persisted before second request")
                if scenario == "cancel-second" { await coordinator.cancel() }
                if scenario == "delete-second" { try store.moveProjectToTrash(projectID: projectID) }
                if scenario == "save-fails" {
                    let backup = store.projectFolder(projectID).appendingPathComponent("project.backup.json")
                    try fm.removeItem(at: backup)
                    try fm.createDirectory(at: backup, withIntermediateDirectories: false)
                }
            case "cancel-immediate": await coordinator.cancel()
            default: break
            }

            try await waitUntil { !coordinator.isRunning }
            let turns = trace(traceURL).filter { $0["type"] as? String == "turn" }
            let saved = store.projects.first { $0.id == projectID }!
            check(coordinator.activeProjectID == nil && coordinator.itemStartedAt == nil, "\(scenario): active state clears after run")
            if scenario == "success" {
                check(turns.count == 3, "one click makes exactly three independent turns; duplicate start adds none")
                check(Set(turns.compactMap { $0["thread"] as? String }).count == 3, "three turns use three independent generation sessions")
                check(turns.allSatisfy { $0["prompt"] as? String == "固定风格\n\n本页内容" }, "all three requests use identical captured input")
                check(saved.pendingImages.count == 3 && Set(saved.pendingImages.map(\.id)).count == 3, "three candidates are separately stored")
                check(saved.pendingImages.allSatisfy { $0.fixedPrompt == "固定风格" && $0.variablePrompt == "本页内容" }, "candidate input snapshots ignore mid-batch edits")
                check(saved.fixedPrompt == "已编辑风格" && saved.variablePrompt == "下一页", "new draft edits remain intact")
                check(coordinator.completedCount == 3 && coordinator.progress(at: Date()) == 1, "only complete persisted batch reaches 100%")
                check(coordinator.latestImageProjectID == projectID && coordinator.latestImageID == saved.pendingImages.last?.id, "last image identity remains available after run")
                let loaded = ProjectStore(root: store.rootURL); try loaded.load()
                check(loaded.projects.first?.pendingImages.count == 3, "completed candidates survive restart")
            } else if scenario == "cancel-immediate" {
                check(turns.isEmpty && saved.pendingImages.isEmpty, "immediate cancellation prevents any native turn")
                check(coordinator.errorMessage == nil, "intentional immediate cancellation has no failure alert")
            } else {
                check(turns.count == 2, "\(scenario): no third request after stop/failure")
                check(saved.pendingImages.count == 1 && coordinator.completedCount == 1, "\(scenario): first saved candidate is retained")
                check(coordinator.progress(at: Date()) < 1, "\(scenario): incomplete batch is never 100%")
                if scenario == "cancel-second" {
                    check(coordinator.errorMessage == nil && trace(traceURL).contains { $0["type"] as? String == "interrupt" }, "cancel sends interrupt without failure alert")
                } else { check(coordinator.errorMessage != nil, "\(scenario): failure is surfaced") }
                if scenario == "delete-second" { check(saved.deletedAt != nil, "deleted project is not mutated by later image response") }
            }
            service.shutdown()
        }
        print("\(checks) GENERATION CHECKS PASSED")
    }

    enum TestFailure: Error { case timeout }

    private static let fakeSource = #"""
#!/usr/bin/python3
import json, os, sys, threading, time
if '--version' in sys.argv:
    print('codex-cli 0.163.0'); sys.exit(0)
lock = threading.Lock()
threads = 0
mode = os.environ['PPT_BATCH_SCENARIO']
def send(value):
    with lock: print(json.dumps(value), flush=True)
def record(value):
    with lock:
        with open(os.environ['PPT_BATCH_TRACE'], 'a') as f: f.write(json.dumps(value)+'\n')
def reply(req, result): send({'id':req['id'], 'result':result})
def turn(req):
    thread = req['params']['threadId']; index = int(thread.split('-')[-1]); turnid = 'turn-'+str(index)
    record({'type':'turn','thread':thread,'prompt':req['params']['input'][0]['text']})
    reply(req, {'turn':{'id':turnid}})
    send({'method':'turn/started','params':{'threadId':thread,'turn':{'id':turnid}}})
    if mode == 'cancel-second' and index == 2: return
    time.sleep(0.15 if index == 1 else 0.3)
    if mode == 'second-fails' and index == 2:
        send({'method':'item/completed','params':{'threadId':thread,'item':{'type':'agentMessage','phase':'final_answer','text':'fixture second-image failure'}}})
    else:
        send({'method':'item/completed','params':{'threadId':thread,'item':{'type':'imageGeneration','status':'completed','savedPath':os.environ['PPT_BATCH_IMAGE']}}})
    send({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turnid,'status':'completed'}}})
for line in sys.stdin:
    req=json.loads(line); method=req.get('method')
    if method == 'initialized': continue
    if method in ('initialize','config/read'): reply(req,{})
    elif method == 'account/read': reply(req,{'account':{'type':'chatgpt'}})
    elif method == 'modelProvider/capabilities/read': reply(req,{'imageGeneration':True})
    elif method == 'model/list': reply(req,{'data':[{'model':'fixture','isDefault':True}]})
    elif method == 'thread/start':
        threads+=1; reply(req,{'thread':{'id':'thread-'+str(threads)}})
    elif method == 'turn/start': threading.Thread(target=turn,args=(req,),daemon=True).start()
    elif method == 'turn/interrupt':
        record({'type':'interrupt'}); reply(req,{})
        send({'method':'turn/completed','params':{'threadId':req['params']['threadId'],'turn':{'id':req['params']['turnId'],'status':'interrupted'}}})
    else: reply(req,{})
"""#
}
