import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        List(selection: sectionSelection) {
            ForEach(LibrarySection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .navigationTitle("Crypta")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }

    private var sectionSelection: Binding<LibrarySection?> {
        Binding(
            get: { library.selectedSection },
            set: { nextSection in
                guard let nextSection else { return }
                Task { await library.selectSection(nextSection) }
            }
        )
    }
}

struct VideoListPage: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        Group {
            if library.visibleVideos.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: library.selectedSection.systemImage)
                } description: {
                    Text(emptyDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                List(selection: $library.selectedVideoID) {
                    ForEach(library.visibleVideos) { video in
                        VideoRow(video: video)
                            .tag(video.id)
                            .contextMenu {
                                Button("重命名") {
                                    library.requestRename(video)
                                }
                            }
                            .onTapGesture {
                                library.selectedVideoID = video.id
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle(library.selectedSection.title)
    }

    private var emptyTitle: String {
        switch library.selectedSection {
        case .plain: return "无视频"
        case .encrypted: return "无加密视频"
        }
    }

    private var emptyDescription: String {
        switch library.selectedSection {
        case .plain: return "拖拽以导入视频"
        case .encrypted: return "拖拽以导入加密视频"
        }
    }
}

struct VideoRow: View {
    let video: CryptaVideo
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(video: video, thumbnail: thumbnail)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayName)
                    .lineLimit(1)
                Text(video.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .task(id: video.id) {
            thumbnail = await VideoThumbnailLoader.thumbnail(for: video)
        }
    }
}

struct ThumbnailView: View {
    let video: CryptaVideo
    let thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: video.storageState == .plain ? "video.fill" : "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(video.storageState == .plain ? Color.secondary : Color.accentColor)
            }
        }
        .frame(width: 64, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct RenameVideoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let request: RenameRequest
    let onSave: (String) -> Void

    init(request: RenameRequest, onSave: @escaping (String) -> Void) {
        self.request = request
        self.onSave = onSave
        self._name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名")
                .font(.title3.weight(.semibold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
    }
}
