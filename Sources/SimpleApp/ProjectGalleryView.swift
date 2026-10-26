import SwiftUI

struct ProjectGalleryView: View {
    @ObservedObject var store: ProjectStore
    @AppStorage("galleryCollapsed") private var galleryCollapsed = false
    let project: SimpleProject
    let selectedImageID: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (ProjectImage, Int) -> Void
    let onTrash: () -> Void
    let onExport: () -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("项目图库").font(.system(size: 15, weight: .semibold))
                Text("\(project.confirmedImages.count) 张已入库 · 拖动缩略图调整顺序")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { galleryCollapsed.toggle() } label: {
                    Label(galleryCollapsed ? "展开图库" : "收起图库", systemImage: galleryCollapsed ? "chevron.down" : "chevron.up")
                }.help("收起图库可增加图片预览高度").accessibilityIdentifier("toggle-gallery")
                Button(action: onExport) { Label("合并导出", systemImage: "square.and.arrow.up") }
                    .disabled(project.confirmedImages.isEmpty).accessibilityIdentifier("export-gallery")
                Button(action: onTrash) { Label("垃圾箱（\(project.trashedImages.count)）", systemImage: "trash") }
                    .accessibilityIdentifier("open-project-trash")
            }
            if !galleryCollapsed {
            if project.confirmedImages.isEmpty {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(project.trashedImages.isEmpty ? "确认入库后的图片会在这里集中展示。" : "图库暂无图片，可从垃圾箱恢复，或生成并确认新图片。")
                }.font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(height: 95).frame(maxWidth: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(project.confirmedImages.enumerated()), id: \.element.id) { index, image in
                            card(image, index: index)
                        }
                        if project.confirmedImages.count > 1 {
                            GalleryDragPreview(projectID: project.id, imageID: nil, imageURL: nil,
                                isSelected: false, accessibilityLabel: "拖到这里排到末尾", onSelect: {},
                                canDrop: canDrop, onDrop: reorder)
                                .frame(width: 78, height: 90)
                        }
                    }.padding(3)
                }.frame(height: 126)
            }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func card(_ image: ProjectImage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            GalleryDragPreview(projectID: project.id, imageID: image.id,
                imageURL: store.imageURL(projectID: project.id, image: image),
                isSelected: selectedImageID == image.id, accessibilityLabel: "查看已入库图片 \(index + 1)",
                onSelect: { onSelect(image.id) }, canDrop: canDrop, onDrop: reorder)
                .frame(width: 160, height: 90)
            HStack {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text("图片 \(index + 1)").font(.system(size: 12))
                Spacer()
                Button { onDelete(image, index + 1) } label: { Label("删除", systemImage: "trash") }
                    .buttonStyle(.borderless).font(.system(size: 12))
                    .accessibilityLabel("删除已入库图片 \(index + 1)")
            }
        }.frame(width: 160)
        .contextMenu {
            Button("前移") { move(image.id, offset: -1) }.disabled(index == 0)
            Button("后移") { move(image.id, offset: 1) }.disabled(index == project.confirmedImages.count - 1)
            Divider()
            Button("删除到垃圾箱", role: .destructive) { onDelete(image, index + 1) }
        }
    }

    private func canDrop(_ item: GalleryDragPayload) -> Bool {
        item.projectID == project.id && store.activeProjects.first(where: { $0.id == project.id })?
            .confirmedImages.contains(where: { $0.id == item.imageID }) == true
    }

    private func reorder(_ item: GalleryDragPayload, target: UUID?, after: Bool) -> Bool {
        guard let live = store.activeProjects.first(where: { $0.id == project.id }),
              let ids = GalleryOrdering.order(for: item, projectID: project.id,
                currentIDs: live.confirmedImages.map(\.id), targetID: target, after: after) else { return false }
        do { try store.reorderConfirmedImages(projectID: project.id, orderedIDs: ids); return true }
        catch { onError(error.localizedDescription); return false }
    }

    private func move(_ id: UUID, offset: Int) {
        guard let live = store.activeProjects.first(where: { $0.id == project.id }) else { return }
        var ids = live.confirmedImages.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        do { try store.reorderConfirmedImages(projectID: project.id, orderedIDs: ids) }
        catch { onError(error.localizedDescription) }
    }
}
