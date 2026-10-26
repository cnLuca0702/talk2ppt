import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProjectExportView: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var format: ImageExportFormat = .pptx
    @State private var isExporting = false
    @State private var choosingDestination = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var showError = false
    private var project: SimpleProject? { store.activeProjects.first { $0.id == projectID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("合并导出").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.disabled(isExporting || choosingDestination).keyboardShortcut(.cancelAction)
            }
            Text("\(project?.name ?? "项目") · \(project?.confirmedImages.count ?? 0) 页")
                .font(.system(size: 15, weight: .medium))
            Text("按项目图库当前顺序，每张图片一页。页面为 16:9，图片等比居中，比例不符时留白。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if let project, !project.pendingImages.isEmpty {
                Label("还有 \(project.pendingImages.count) 张候选图片未入库，本次仅导出图库图片。", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Picker("文件类型", selection: $format) {
                ForEach(ImageExportFormat.allCases) { value in Text(value.title).tag(value) }
            }.pickerStyle(.segmented).disabled(isExporting || choosingDestination)
            if let project {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(project.confirmedImages.enumerated()), id: \.element.id) { index, image in
                            VStack(alignment: .leading, spacing: 5) {
                                SlidePreview(url: store.imageURL(projectID: project.id, image: image)).frame(width: 140, height: 79)
                                Text("第 \(index + 1) 页").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(height: 110)
            }
            Spacer(minLength: 0)
            if isExporting { ProgressView("正在打包图片…").font(.system(size: 13)) }
            if let exportedURL {
                Label("已导出：\(exportedURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
            }
            HStack {
                Spacer()
                Button("选择保存位置并导出") { chooseDestination() }
                    .buttonStyle(.borderedProminent).disabled(isExporting || choosingDestination || project?.confirmedImages.isEmpty != false)
                    .accessibilityIdentifier("save-image-deck")
            }
        }.padding(24).frame(width: 680, height: 440)
            .interactiveDismissDisabled(isExporting || choosingDestination)
            .alert("导出未完成", isPresented: $showError) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "请重试。") }
    }

    private func chooseDestination() {
        guard !choosingDestination, !isExporting, let project, !project.confirmedImages.isEmpty else { return }
        let selectedFormat = format
        let slides = project.confirmedImages.map { ImageExportSlide(id: $0.id, imageURL: store.imageURL(projectID: project.id, image: $0)) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: selectedFormat.fileExtension) ?? .data]
        panel.nameFieldStringValue = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + selectedFormat.fileExtension
        panel.canCreateDirectories = true
        choosingDestination = true
        panel.begin { response in
            choosingDestination = false
            guard response == .OK, let destination = panel.url else { return }
            isExporting = true
            exportedURL = nil
            Task { @MainActor in
                defer { isExporting = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ImageDeckExporter.export(slides: slides, format: selectedFormat, to: destination)
                    }.value
                    exportedURL = destination
                } catch { errorMessage = error.localizedDescription; showError = true }
            }
        }
    }
}
