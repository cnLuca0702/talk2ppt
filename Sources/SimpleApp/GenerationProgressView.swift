import SwiftUI

struct GenerationProgressView: View {
    @ObservedObject var generation: GenerationCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let progress = generation.progress(at: timeline.date)
            let elapsed = max(0, Int(timeline.date.timeIntervalSince(generation.startedAt ?? timeline.date)))
            VStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.tint)
                Text("正在生成第 \(min(generation.completedCount + 1, generation.requestedCount)) / \(generation.requestedCount) 张")
                    .font(.system(size: 17, weight: .semibold))
                ProgressView(value: progress).frame(maxWidth: 270)
                Text("生成进度（预估）\(Int(progress * 100))% · 已用时 \(elapsed / 60)分\(elapsed % 60)秒")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(generation.status).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                Text("进度根据常见耗时估算，实际完成以图片返回为准。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(CGFloat(16) / 9, contentMode: .fit)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("generation-progress")
    }
}
