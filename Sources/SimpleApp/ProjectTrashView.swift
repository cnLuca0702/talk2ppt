import SwiftUI

struct ProjectTrashView: View {
    @ObservedObject var store: ProjectStore
    let projectID: UUID
    let onRestore: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var restored = false

    private var project: SimpleProject? { store.projects.first { $0.id == projectID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("项目垃圾箱").font(.system(size: 22, weight: .semibold))
                    Text(project?.name ?? "项目不可用").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("移入垃圾箱的原图和生成提示词会一直保留，不会自动清空。恢复后图片会回到本项目图库末尾。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if restored {
                Label("图片已恢复到项目图库", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
            }
            Divider()
            if let project, !project.trashedImages.isEmpty {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], spacing: 18) {
                        ForEach(project.trashedImages.sorted { $0.deletedAt > $1.deletedAt }) { entry in
                            VStack(alignment: .leading, spacing: 9) {
                                SlidePreview(url: store.imageURL(projectID: projectID, image: entry.image))
                                Text(entry.image.variablePrompt.split(separator: "\n").first.map(String.init) ?? "图片")
                                    .font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text("删除于 \(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Button { restore(entry.image.id) } label: {
                                    Label("恢复到图库", systemImage: "arrow.uturn.backward")
                                }.accessibilityIdentifier("restore-trash-image-\(entry.image.id.uuidString)")
                            }
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else {
                ContentUnavailableView("垃圾箱为空", systemImage: "trash", description: Text("从项目图库删除的图片会保留在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(width: 820, height: 590)
        .alert("无法恢复图片", isPresented: $showError) {
            Button("知道了", role: .cancel) {}
        } message: { Text(errorMessage ?? "请重试。") }
    }

    private func restore(_ imageID: UUID) {
        do {
            try store.restoreImage(projectID: projectID, imageID: imageID)
            restored = true
            onRestore(imageID)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
