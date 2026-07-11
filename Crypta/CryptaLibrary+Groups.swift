import Foundation
import SwiftUI

@MainActor
extension CryptaLibrary {
    func createGroup(name: String, encryptionLevel: EncryptionLevel, mediaType: MediaType) async {
        let group = LibraryGroup(name: name, encryptionLevel: encryptionLevel, mediaType: mediaType)
        do {
            try store.createGroup(group)
            groups.append(group)
            if selectedGroupID == nil {
                selectedGroupID = group.id
            }
            showToast("已创建保险箱")
        } catch {
            showToast("创建保险箱失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func renameGroup(_ request: EditGroupRequest, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.renameGroup(id: request.group.id, to: trimmed)
            if let index = groups.firstIndex(where: { $0.id == request.group.id }) {
                groups[index].name = trimmed
            }
            editGroupRequest = nil
            showToast("已重命名")
        } catch {
            showToast("重命名失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(_ group: LibraryGroup) async {
        guard !videos.contains(where: { $0.libraryKind.rawValue == group.id }) else {
            showToast("保险箱内仍有文件，无法删除", kind: .error)
            return
        }
        do {
            try store.deleteGroup(id: group.id)
            lockGroupAccess(group.id)
            groups.removeAll { $0.id == group.id }
            if selectedGroupID == group.id {
                selectedGroupID = groups.first?.id
            }
            showToast("已删除保险箱")
        } catch {
            showToast("删除保险箱失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func requestEditGroup(_ group: LibraryGroup) {
        editGroupRequest = EditGroupRequest(group: group)
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var updated = groups
        updated.move(fromOffsets: source, toOffset: destination)
        let previous = groups
        groups = updated
        do {
            try store.saveGroupOrder(updated)
        } catch {
            groups = previous
            showToast("调整顺序失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }
}
