import SwiftUI
import AppKit

@MainActor final class YingGaoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                if window.frame.width < 800 || window.frame.height < 600 {
                    window.setContentSize(NSSize(width: 1240, height: 850))
                    window.center()
                }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main struct YingGaoApp: App {
    @NSApplicationDelegateAdaptor(YingGaoDelegate.self) private var appDelegate
    @StateObject private var store = ProjectStore(root: Self.testRoot)
    private static var testRoot: URL? {
        #if UI_TESTING
        var requestedPath = Bundle.main.object(forInfoDictionaryKey: "UITestProjectsPath") as? String
        if let index = CommandLine.arguments.firstIndex(of: "--ui-test-projects"), CommandLine.arguments.indices.contains(index + 1) {
            requestedPath = CommandLine.arguments[index + 1]
        }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        if let path = requestedPath {
            let requested = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            guard requested.path.hasPrefix(temporary.path + "/") else {
                fatalError("UI tests require an isolated temporary directory")
            }
            return requested
        }
        return temporary.appendingPathComponent("YingGaoUIFixture-\(UUID().uuidString)/Projects", isDirectory: true)
        #else
        return nil
        #endif
    }
    @StateObject private var service = CodexImageService()
    var body: some Scene {
        WindowGroup("映稿") { SimpleWorkspace(store: store, service: service) }
            .defaultSize(width: 1240, height: 850)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct SimpleWorkspace: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var service: CodexImageService
    @State private var selectedID: UUID?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var clearedVariables: [UUID: String] = [:]
    @AppStorage("promptPanelCollapsed") private var promptPanelCollapsed = false
    @State private var viewedImageID: UUID?
    @State private var creating = false
    @State private var projectName = ""
    @State private var localError: String?
    @State private var showError = false
    @State private var imageZoom = false
    @StateObject private var generation: GenerationCoordinator
    @State private var generationCount = 1
    @State private var blankPreviewProjects: Set<UUID> = []
    @State private var exportProject: TrashProjectSelection?
    @State private var showDeletedProjects = false
    @State private var projectDeleteRequest: ProjectDeleteRequest?
    @State private var copied = false
    @State private var imageCopied = false
    @State private var deleteRequest: GalleryDeleteRequest?
    @State private var trashProject: TrashProjectSelection?
    @State private var hasLoaded = false
    @State private var saveFailureProjects: Set<UUID> = []
    @AppStorage("fixedPromptCollapsed") private var fixedPromptCollapsed = false
    init(store: ProjectStore, service: CodexImageService) {
        self.store = store
        self.service = service
        _generation = StateObject(wrappedValue: GenerationCoordinator(service: service, store: store))
    }
    var generatingProjectID: UUID? { generation.isRunning ? generation.activeProjectID : nil }
    var saveIssue: Bool { selectedID.map { saveFailureProjects.contains($0) } ?? false }
    var project: SimpleProject? { store.activeProjects.first { $0.id == selectedID } }
    var shownImage: ProjectImage? {
        guard let p = project, generatingProjectID != p.id, !blankPreviewProjects.contains(p.id) else { return nil }
        if let id = viewedImageID {
            return (p.confirmedImages + p.pendingImages).first { $0.id == id } ?? p.pendingImage ?? p.confirmedImages.last
        }
        return p.pendingImage ?? p.confirmedImages.last
    }
    var shownURL: URL? { guard let p = project, let img = shownImage else { return nil }; return store.imageURL(projectID: p.id, image: img) }
    var showingPending: Bool { guard let id = shownImage?.id else { return false }; return project?.pendingImages.contains { $0.id == id } == true }
    var canGenerate: Bool {
        guard let p = project else { return false }
        return service.isReady && !service.isBusy && generatingProjectID == nil && !saveIssue &&
        !(p.fixedPrompt + p.variablePrompt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Image(systemName: "photo.stack.fill").foregroundStyle(.tint); Text("映稿").font(.system(size: 23, weight: .semibold)); Spacer() }.padding(.top, 12)
                Text("把每一张好图留在项目里").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { newProject() } label: { Label("新建项目", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("new-project")
                List(selection: $selectedID) {
                    ForEach(store.activeProjects) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.name).font(.system(size: 14, weight: .medium)).lineLimit(2)
                            HStack(spacing: 5) { Text("\(p.confirmedImages.count) 张已入库"); if generatingProjectID == p.id { Text("· 生成中") } else if !p.pendingImages.isEmpty { Text("· \(p.pendingImages.count) 张待入库") } }.font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(p.id)
                        .contextMenu {
                            Button("删除项目", role: .destructive) { requestProjectDeletion(p) }
                                .disabled(generatingProjectID == p.id)
                        }
                    }
                }.listStyle(.sidebar)
                Button { showDeletedProjects = true } label: { Label("已删除项目（\(store.deletedProjects.count)）", systemImage: "folder.badge.minus") }
                    .accessibilityIdentifier("deleted-projects")
                Divider()
                #if !UI_TESTING
                VStack(alignment: .leading, spacing: 9) {
                    Label(service.isReady ? "ChatGPT 已连接" : "ChatGPT 连接", systemImage: service.isReady ? "checkmark.seal.fill" : "person.crop.circle")
                        .foregroundStyle(service.isReady ? Color.green : Color.secondary).font(.system(size: 13, weight: .medium))
                    Text(generation.isRunning ? generation.status : service.status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !service.isReady {
                        Button("Sign in with ChatGPT") { Task { await service.signIn() } }.disabled(service.isBusy)
                        Button("重新检查连接") { Task { await service.connect() } }.disabled(service.isBusy)
                    }
                }
                #endif
                #if UI_TESTING
                Text("离线界面测试 · 使用独立项目目录").font(.system(size: 12)).foregroundStyle(.orange)
                #endif
                Text("图片与提示词保存在本机").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(14)
            .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 310)
            .alert("删除这个项目？", isPresented: Binding(get: { projectDeleteRequest != nil }, set: { if !$0 { projectDeleteRequest = nil } }), presenting: projectDeleteRequest) { request in
                Button("取消", role: .cancel) {}
                Button("删除项目", role: .destructive) { deleteProject(request) }
            } message: { request in
                Text("“\(request.name)”会移入“已删除项目”，图片与提示词全部保留，可随时恢复。")
            }
        } detail: {
            if let p = project { projectWorkspace(p) }
            else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.stack").font(.system(size: 48)).foregroundStyle(.blue)
                    Text("从一个项目开始").font(.system(size: 25, weight: .semibold))
                    Text("填写两段提示词，生成图片。\n满意后确认，同一项目的图片会集中保留。").font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("新建项目") { newProject() }.buttonStyle(.borderedProminent).controlSize(.large)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1080, minHeight: 740)
        .toolbar {
            ToolbarItem {
                if project != nil {
                    Button { promptPanelCollapsed.toggle() } label: {
                        Label(promptPanelCollapsed ? "展开提示词" : "收起提示词", systemImage: "text.alignleft").labelStyle(.titleAndIcon)
                    }.help(promptPanelCollapsed ? "展开提示词与生成设置" : "收起提示词，扩大图片预览")
                        .accessibilityIdentifier("toggle-prompt-panel")
                }
            }
            ToolbarItem { if let p = project { Button { NSWorkspace.shared.open(store.projectFolder(p.id)) } label: { Label("在 Finder 中查看", systemImage: "folder") }.help("查看项目数据与原始图片") } }
        }
        .sheet(isPresented: $creating) { newProjectSheet }
        .sheet(isPresented: $showDeletedProjects) {
            DeletedProjectsView(store: store) { id in selectedID = id }
        }
        .sheet(item: $exportProject) { selection in ProjectExportView(store: store, projectID: selection.id) }
        .sheet(item: $trashProject) { selection in
            ProjectTrashView(store: store, projectID: selection.id) { imageID in
                if selectedID == selection.id { blankPreviewProjects.remove(selection.id); viewedImageID = imageID }
            }
        }
        .sheet(isPresented: $imageZoom) { VStack(spacing: 12) { HStack { Text("图片预览").font(.headline); Spacer(); copyImageButton; Button("关闭") { imageZoom = false }.keyboardShortcut(.cancelAction) }; SlidePreview(url: shownURL); if let url = shownURL { Button("用预览打开原图") { NSWorkspace.shared.open(url) } } }.padding(20).frame(width: 1000, height: 650) }
        .alert("暂时无法完成", isPresented: $showError) { Button("知道了", role: .cancel) {} } message: { Text(localError ?? "未知错误") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in service.shutdown() }
        .onChange(of: selectedID) { viewedImageID = nil; copied = false }
        .onChange(of: shownURL) { imageCopied = false }
        .onChange(of: service.errorMessage) { if !generation.isRunning, let error = service.errorMessage { report(error) } }
        .onChange(of: generation.errorMessage) { if let error = generation.errorMessage { report(error) } }
        .onChange(of: generation.latestImageID) {
            if let imageID = generation.latestImageID, let projectID = generation.latestImageProjectID {
                blankPreviewProjects.remove(projectID)
                if selectedID == projectID { viewedImageID = imageID }
            }
        }
        .task {
            guard !hasLoaded else { return }; hasLoaded = true
            do { try store.load(); selectedID = store.activeProjects.first?.id; if let error = store.errorMessage { report(error) } } catch { report(error.localizedDescription) }
            #if !UI_TESTING
            await service.connect()
            #endif
        }
    }
    func projectWorkspace(_ p: SimpleProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) { Text(p.name).font(.system(size: 23, weight: .semibold)); Text(saveIssue ? "保存失败，请重试编辑后再生成" : "提示词自动保存 · 固定提示词在项目内持续复用").font(.system(size: 12)).foregroundStyle(saveIssue ? Color.red : Color.secondary) }
                Spacer()
                if generatingProjectID == p.id { ProgressView().controlSize(.small); Text("正在生成").font(.system(size: 13)).foregroundStyle(.secondary) }
                Menu { Button("删除项目", role: .destructive) { requestProjectDeletion(p) }.disabled(generatingProjectID == p.id) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28).help("项目操作")
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            HSplitView {
                if !promptPanelCollapsed {
                    promptPanel(p)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
                }
                previewPanel(p)
                    .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: 370, maxHeight: .infinity)
            Divider()
            ProjectGalleryView(store: store, project: p, selectedImageID: shownImage?.id,
                onSelect: { id in blankPreviewProjects.remove(p.id); viewedImageID = id },
                onDelete: { image, number in deleteRequest = GalleryDeleteRequest(projectID: p.id, imageID: image.id, projectName: p.name, imageNumber: number) },
                onTrash: { trashProject = TrashProjectSelection(id: p.id) },
                onExport: { exportProject = TrashProjectSelection(id: p.id) },
                onError: report)
                .alert("将这张图片移入垃圾箱？", isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } }), presenting: deleteRequest) { request in
                    Button("取消", role: .cancel) {}
                    Button("移入垃圾箱", role: .destructive) { moveToTrash(request) }
                } message: { request in
                    Text("将删除“\(request.projectName)”图库中的图片 \(request.imageNumber)。原图和生成提示词会保留在该项目垃圾箱中，可随时恢复。")
                }
        }
    }
    func promptPanel(_ p: SimpleProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("固定提示词", systemImage: "pin").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { fixedPromptCollapsed.toggle() } label: {
                    Label(fixedPromptCollapsed ? "展开" : "收起", systemImage: fixedPromptCollapsed ? "chevron.down" : "chevron.up")
                }.accessibilityIdentifier("toggle-fixed-prompt")
                    .help(fixedPromptCollapsed ? "展开固定提示词" : "收起后，生成时仍会合并使用")
            }
            if fixedPromptCollapsed {
                Text(p.fixedPrompt.isEmpty ? "尚未填写，展开后可编辑。" : "已保存 \(p.fixedPrompt.count) 字 · 生成时仍会使用")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("整组图片共用的风格、比例和要求。").font(.system(size: 12)).foregroundStyle(.secondary)
                promptEditor(promptBinding(fixed: true), placeholder: "例如：横版 16:9，白色背景、低饱和蓝色，简洁专业，中文清晰。", id: "fixed-prompt")
            }
            HStack {
                Label("可变提示词", systemImage: "text.cursor").font(.system(size: 14, weight: .semibold))
                Spacer()
                if clearedVariables[p.id] != nil && p.variablePrompt.isEmpty {
                    Button("撤销清空") { restoreVariable(p) }.accessibilityIdentifier("undo-clear-variable")
                }
                Button { clearVariable(p) } label: { Label("清空", systemImage: "xmark.circle") }
                    .disabled(p.variablePrompt.isEmpty).help("只清空可变提示词，固定提示词保持不变")
                    .accessibilityIdentifier("clear-variable-prompt")
            }.padding(.top, 4)
            Text("本次图片的内容；做下一张时替换这里。").font(.system(size: 12)).foregroundStyle(.secondary)
            promptEditor(promptBinding(fixed: false), placeholder: "例如：标题“工作流程”，以流程图呈现输入、生成、确认三个步骤。", id: "variable-prompt")
            HStack {
                Text("固定＋可变 → 生图").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制完整提示词") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(joinedPrompt(p), forType: .string); copied = true
                }.disabled((p.fixedPrompt + p.variablePrompt).isEmpty)
            }
            Divider().padding(.vertical, 2)
            generationControls(p, compact: false)
        }.padding(16)
    }
    func previewPanel(_ p: SimpleProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("图片预览").font(.system(size: 14, weight: .semibold))
                if shownImage != nil { Text("点击图片放大").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                Text("16:9").font(.system(size: 12)).foregroundStyle(.secondary)
                copyImageButton
                if shownImage != nil { Button("放大") { imageZoom = true } }
            }
            if promptPanelCollapsed { generationControls(p, compact: true) }
            GeometryReader { geometry in
                Group {
                    if generatingProjectID == p.id {
                        GenerationProgressView(generation: generation)
                    } else if shownURL != nil {
                        Button { imageZoom = true } label: {
                            SlidePreview(url: shownURL)
                        }.buttonStyle(.plain).contentShape(Rectangle())
                            .help("点击放大查看原图")
                            .accessibilityLabel("放大当前预览图片")
                            .accessibilityIdentifier("image-preview")
                    } else {
                        SlidePreview(url: nil).accessibilityIdentifier("image-preview")
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if generatingProjectID != p.id && p.pendingImages.count > 1 { candidatePicker(p) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if shownImage != nil {
                        Label(showingPending ? "待入库 · 确认后加入下方图库" : "已入库 · 可在下方排序和导出", systemImage: showingPending ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(showingPending ? Color.orange : Color.green)
                    } else {
                        Text(generatingProjectID == p.id ? "图片完成后，可选择并确认入库" : "填写提示词后，点击“生成图片”开始").foregroundStyle(.secondary)
                    }
                    if let img = shownImage, img.fixedPrompt != p.fixedPrompt || img.variablePrompt != p.variablePrompt {
                        Text("提示词已修改，当前图片仍对应之前的内容。").foregroundStyle(.secondary)
                    }
                }.font(.system(size: 12))
                Spacer(minLength: 4)
                if !p.pendingImages.isEmpty && !showingPending && generatingProjectID != p.id {
                    Button("查看待入库") { blankPreviewProjects.remove(p.id); viewedImageID = p.pendingImage?.id }
                }
                Button { confirm(p) } label: { Label("确认入库", systemImage: "checkmark").fixedSize() }
                    .controlSize(.large).disabled(!showingPending || generatingProjectID == p.id)
                    .help(showingPending ? "将当前选中图片加入项目图库" : "生成并选择一张待入库图片后可用")
                    .accessibilityIdentifier("confirm-image")
            }
        }.padding(16)
    }
    func generationControls(_ p: SimpleProject, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                HStack(spacing: 12) {
                    generationQuantity
                    generateButton(p)
                    if generatingProjectID == p.id { Button("停止生成") { Task { await generation.cancel() } } }
                    Spacer(minLength: 0)
                }
            } else {
                generationQuantity
                HStack {
                    generateButton(p)
                    if generatingProjectID == p.id { Button("停止生成") { Task { await generation.cancel() } } }
                }
                Text(generationCount == 3 ? "依次生成 3 个方案，选中满意的一张再确认入库。" : "生成后点击图片检查，满意后确认入库。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var generationQuantity: some View {
        HStack(spacing: 12) {
            Text("生成数量").font(.system(size: 13)).fixedSize()
            Picker("生成数量", selection: $generationCount) {
                Text("1 张").tag(1)
                Text("3 张选 1").tag(3)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 172)
                .disabled(generation.isRunning).accessibilityIdentifier("generation-count")
        }
    }
    func generateButton(_ p: SimpleProject) -> some View {
        Button { generate(p) } label: {
            Label(generationCount == 3 ? "生成 3 张候选" : "生成图片", systemImage: "sparkles")
                .frame(maxWidth: promptPanelCollapsed ? nil : .infinity)
        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canGenerate)
            .accessibilityIdentifier("generate-image")
    }
    func clearVariable(_ p: SimpleProject) {
        guard !p.variablePrompt.isEmpty else { return }
        do {
            try store.updatePrompts(projectID: p.id, fixed: p.fixedPrompt, variable: "")
            clearedVariables[p.id] = p.variablePrompt
            saveFailureProjects.remove(p.id); copied = false
        } catch { saveFailureProjects.insert(p.id); report(error.localizedDescription) }
    }
    func restoreVariable(_ p: SimpleProject) {
        guard p.variablePrompt.isEmpty, let value = clearedVariables[p.id] else { return }
        do {
            try store.updatePrompts(projectID: p.id, fixed: p.fixedPrompt, variable: value)
            clearedVariables.removeValue(forKey: p.id)
            saveFailureProjects.remove(p.id); copied = false
        } catch { saveFailureProjects.insert(p.id); report(error.localizedDescription) }
    }
    func promptEditor(_ binding: Binding<String>, placeholder: String, id: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: binding).font(.system(size: 15)).padding(7).scrollContentBackground(.hidden).accessibilityIdentifier(id).accessibilityLabel(id == "fixed-prompt" ? "固定提示词" : "可变提示词")
            if binding.wrappedValue.isEmpty { Text(placeholder).font(.system(size: 14)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 15).allowsHitTesting(false) }
        }.frame(minHeight: 80, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
    }
    func promptBinding(fixed: Bool) -> Binding<String> {
        Binding(get: { fixed ? project?.fixedPrompt ?? "" : project?.variablePrompt ?? "" }, set: { value in
            guard let p = project else { return }
            do { try store.updatePrompts(projectID: p.id, fixed: fixed ? value : p.fixedPrompt, variable: fixed ? p.variablePrompt : value); saveFailureProjects.remove(p.id); copied = false; if !fixed { clearedVariables.removeValue(forKey: p.id) } }
            catch { saveFailureProjects.insert(p.id); report(error.localizedDescription) }
        })
    }
    func joinedPrompt(_ p: SimpleProject) -> String { [p.fixedPrompt, p.variablePrompt].filter { !$0.isEmpty }.joined(separator: "\n\n") }
    var copyImageButton: some View {
        Button(action: copyPreviewImage) {
            Label(imageCopied ? "已复制" : "复制", systemImage: imageCopied ? "checkmark" : "doc.on.doc")
        }
        .disabled(shownURL == nil)
        .help("将当前预览的原始图片复制到剪贴板")
        .accessibilityIdentifier("copy-preview-image")
    }
    func copyPreviewImage() {
        guard let url = shownURL else { return }
        do {
            let original = try Data(contentsOf: url)
            guard let image = NSImage(data: original), let tiff = image.tiffRepresentation,
                  let png = url.pathExtension.lowercased() == "png" ? original : NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                report("无法读取这张图片，请检查项目中的原图文件。")
                return
            }
            // Prepare both formats before replacing the clipboard. PNG retains the original bytes.
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setData(tiff, forType: .tiff)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                report("无法将图片写入剪贴板，请再试一次。")
                return
            }
            imageCopied = true
        } catch { report("复制图片失败：\(error.localizedDescription)") }
    }
    func candidatePicker(_ p: SimpleProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Array(p.pendingImages.enumerated()), id: \.element.id) { index, image in
                    Button { viewedImageID = image.id; blankPreviewProjects.remove(p.id) } label: {
                        VStack(spacing: 4) {
                            SlidePreview(url: store.imageURL(projectID: p.id, image: image)).frame(width: 104, height: 59)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(shownImage?.id == image.id ? Color.accentColor : .clear, lineWidth: 2))
                            Text("候选 \(index + 1)").font(.system(size: 12))
                        }
                    }.buttonStyle(.plain).accessibilityLabel("选择候选图片 \(index + 1)")
                }
            }
            Text("选择一张确认入库，其余候选会保留在垃圾箱。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    func generate(_ p: SimpleProject) {
        guard canGenerate else { return }
        blankPreviewProjects.insert(p.id)
        viewedImageID = nil
        imageZoom = false
        generation.start(project: p, count: generationCount)
    }
    func requestProjectDeletion(_ p: SimpleProject) {
        guard generatingProjectID != p.id else { return }
        projectDeleteRequest = ProjectDeleteRequest(id: p.id, name: p.name)
    }
    func deleteProject(_ request: ProjectDeleteRequest) {
        guard generatingProjectID != request.id else { report("这个项目仍在生成，请先停止生成后再删除。"); return }
        do {
            try store.moveProjectToTrash(projectID: request.id)
            if selectedID == request.id { selectedID = store.activeProjects.first?.id }
        } catch { report(error.localizedDescription) }
    }
    func confirm(_ p: SimpleProject) {
        guard showingPending, let image = shownImage else { return }
        do { try store.confirmImage(projectID: p.id, imageID: image.id); blankPreviewProjects.remove(p.id); viewedImageID = image.id }
        catch { report(error.localizedDescription) }
    }
    func moveToTrash(_ request: GalleryDeleteRequest) {
        do {
            try store.moveImageToTrash(projectID: request.projectID, imageID: request.imageID)
            if selectedID == request.projectID, viewedImageID == request.imageID { viewedImageID = nil }
        } catch { report(error.localizedDescription) }
    }
    func newProject() { projectName = ""; creating = true }
    var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建项目").font(.system(size: 22, weight: .semibold))
            Text("提示词和确认后的图片会保存在这个项目中。").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("项目名称", text: $projectName).textFieldStyle(.roundedBorder).font(.system(size: 15)).accessibilityIdentifier("project-name").onSubmit { createProject() }
            HStack { Spacer(); Button("取消") { creating = false }.keyboardShortcut(.cancelAction); Button("创建项目") { createProject() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(26).frame(width: 430)
    }
    func createProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        do { selectedID = try store.create(name: name); viewedImageID = nil; creating = false }
        catch { report(error.localizedDescription) }
    }
    func report(_ text: String) { localError = text; showError = true }
}

struct ProjectDeleteRequest {
    let id: UUID
    let name: String
}

struct GalleryDeleteRequest {
    let projectID: UUID
    let imageID: UUID
    let projectName: String
    let imageNumber: Int
}

struct TrashProjectSelection: Identifiable {
    let id: UUID
}

struct SlidePreview: View {
    var url: URL?
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let url, let image = NSImage(contentsOf: url) {
                GeometryReader { geo in Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: geo.size.width, height: geo.size.height) }
            } else {
                VStack(spacing: 9) { Image(systemName: "photo").font(.system(size: 30)); Text("图片预览").font(.system(size: 13)) }.foregroundStyle(.tertiary)
            }
        }.aspectRatio(CGFloat(16) / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)))
    }
}
