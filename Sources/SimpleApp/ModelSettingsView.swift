import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var service: CodexImageService
    let generationRunning: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var selectionError: String?

    private var locked: Bool {
        #if UI_TESTING
        return generationRunning || service.isBusy || service.isLoadingModels
        #else
        return generationRunning || service.isBusy || service.isLoadingModels || !service.isReady
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择调用模型").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Label("Sign in with ChatGPT · 原生 image-gen", systemImage: "checkmark.shield")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("选择负责理解提示词、调用生图工具的模型。image-gen 的底层图像模型由 ChatGPT 运行时管理。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if service.availableModels.isEmpty {
                ContentUnavailableView("暂无模型列表", systemImage: "cpu", description: Text("请先通过 Sign in with ChatGPT 连接，然后刷新列表。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(service.availableModels) { model in
                    Button {
                        selectedID = model.id
                        selectionError = nil
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedID == model.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selectedID == model.id ? Color.accentColor : .secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(model.displayName).font(.system(size: 14, weight: .medium))
                                    if service.selectedModelID == model.id { Text("当前").foregroundStyle(.tint) }
                                    if model.isDefault { Text("默认").foregroundStyle(.secondary) }
                                }
                                Text(model.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                if let description = model.description, !description.isEmpty {
                                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(locked)
                        .accessibilityLabel("选择模型 \(model.displayName)")
                        .accessibilityIdentifier("model-option-\(model.id)")
                }.listStyle(.inset).accessibilityIdentifier("model-list")
            }
            if let notice = service.modelSelectionNotice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = selectionError ?? service.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }
            Text(generationRunning || service.isBusy ? "正在生成图片，完成或停止后可切换模型。" : "选择会保存在本机，从下一次生成开始使用。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("刷新列表") {
                    Task { await service.refreshModels() }
                }.disabled(locked || !service.isReady).accessibilityIdentifier("refresh-models")
                if service.isLoadingModels { ProgressView().controlSize(.small) }
                Spacer()
                Button("使用所选模型") {
                    guard let selectedID else { return }
                    do { try service.selectModel(selectedID); dismiss() }
                    catch { selectionError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(locked || selectedID == nil || !service.availableModels.contains { $0.id == selectedID })
                    .accessibilityIdentifier("apply-model")
            }
        }.padding(24).frame(width: 570, height: 560)
            .onAppear { selectedID = service.selectedModelID }
            .onChange(of: service.availableModels) {
                if !service.availableModels.contains(where: { $0.id == selectedID }) { selectedID = service.selectedModelID }
            }
    }
}
