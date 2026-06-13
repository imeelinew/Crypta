import SwiftUI
import UniformTypeIdentifiers

struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var encryptionLevel: EncryptionLevel = .standard
    @State private var mediaType: MediaType = .video
    let onCreate: (String, EncryptionLevel, MediaType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建保险箱")
                .font(.title3.weight(.semibold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            VStack(alignment: .leading, spacing: 6) {
                Text("访问控制级别")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $encryptionLevel) {
                    ForEach(EncryptionLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("存储媒介")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $mediaType) {
                    ForEach(MediaType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("创建") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed, encryptionLevel, mediaType)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}

struct EditGroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let request: EditGroupRequest
    let onSave: (String) -> Void

    init(request: EditGroupRequest, onSave: @escaping (String) -> Void) {
        self.request = request
        self.onSave = onSave
        self._name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑保险箱名称")
                .font(.title3.weight(.semibold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}
