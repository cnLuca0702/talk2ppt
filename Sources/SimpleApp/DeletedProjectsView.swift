import SwiftUI

struct DeletedProjectsView: View {
    @ObservedObject var store: ProjectStore
    let onRestore: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("已删除项目").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("项目的提示词、图库、候选图片和垃圾箱都会保留，可随时恢复。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if store.deletedProjects.isEmpty {
                ContentUnavailableView("没有已删除项目", systemImage: "folder.badge.minus")
            } else {
                List(store.deletedProjects) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name).font(.system(size: 15, weight: .medium))
                            Text("\(project.confirmedImages.count) 张已入库 · \(project.pendingImages.count) 张候选图片")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复项目") {
                            do { try store.restoreProject(projectID: project.id); onRestore(project.id) }
                            catch { errorMessage = error.localizedDescription; showError = true }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.padding(24).frame(width: 660, height: 450)
            .alert("无法恢复项目", isPresented: $showError) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "请重试。") }
    }
}
