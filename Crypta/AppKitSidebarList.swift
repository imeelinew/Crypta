import AppKit
import SwiftUI

struct AppKitSidebarList: NSViewRepresentable {
    var groups: [LibraryGroup]
    var selectedGroupID: String?
    var isGroupUnlocked: (LibraryGroup) -> Bool
    var canManuallyLock: (LibraryGroup) -> Bool
    var canDeleteGroup: (LibraryGroup) -> Bool
    var onSelectGroup: (LibraryGroup) -> Void
    var onMove: (IndexSet, Int) -> Void
    var onLock: (LibraryGroup) -> Void
    var onRename: (LibraryGroup) -> Void
    var onDelete: (LibraryGroup) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            groups: groups,
            selectedGroupID: selectedGroupID,
            isGroupUnlocked: isGroupUnlocked,
            canManuallyLock: canManuallyLock,
            canDeleteGroup: canDeleteGroup,
            onSelectGroup: onSelectGroup,
            onMove: onMove,
            onLock: onLock,
            onRename: onRename,
            onDelete: onDelete
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            groups: groups,
            selectedGroupID: selectedGroupID,
            isGroupUnlocked: isGroupUnlocked,
            canManuallyLock: canManuallyLock,
            canDeleteGroup: canDeleteGroup,
            onSelectGroup: onSelectGroup,
            onMove: onMove,
            onLock: onLock,
            onRename: onRename,
            onDelete: onDelete
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var groups: [LibraryGroup]
        private var selectedGroupID: String?
        private var isGroupUnlocked: (LibraryGroup) -> Bool
        private var canManuallyLock: (LibraryGroup) -> Bool
        private var canDeleteGroup: (LibraryGroup) -> Bool
        private var onSelectGroup: (LibraryGroup) -> Void
        private var onMove: (IndexSet, Int) -> Void
        private var onLock: (LibraryGroup) -> Void
        private var onRename: (LibraryGroup) -> Void
        private var onDelete: (LibraryGroup) -> Void

        private weak var tableView: SidebarTableView?
        private var isSyncingSelection = false
        private var unlockedGroupIDs: Set<String> = []

        init(
            groups: [LibraryGroup],
            selectedGroupID: String?,
            isGroupUnlocked: @escaping (LibraryGroup) -> Bool,
            canManuallyLock: @escaping (LibraryGroup) -> Bool,
            canDeleteGroup: @escaping (LibraryGroup) -> Bool,
            onSelectGroup: @escaping (LibraryGroup) -> Void,
            onMove: @escaping (IndexSet, Int) -> Void,
            onLock: @escaping (LibraryGroup) -> Void,
            onRename: @escaping (LibraryGroup) -> Void,
            onDelete: @escaping (LibraryGroup) -> Void
        ) {
            self.groups = groups
            self.selectedGroupID = selectedGroupID
            self.isGroupUnlocked = isGroupUnlocked
            self.canManuallyLock = canManuallyLock
            self.canDeleteGroup = canDeleteGroup
            self.onSelectGroup = onSelectGroup
            self.onMove = onMove
            self.onLock = onLock
            self.onRename = onRename
            self.onDelete = onDelete
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true

            let tableView = SidebarTableView()
            tableView.menuDelegate = self
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.backgroundColor = .clear
            tableView.style = .sourceList
            tableView.rowHeight = 32
            tableView.intercellSpacing = NSSize(width: 0, height: 2)
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = false
            tableView.registerForDraggedTypes([.string])
            tableView.setDraggingSourceOperationMask(.move, forLocal: true)

            let column = NSTableColumn(identifier: .sidebarMainColumn)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            scrollView.documentView = tableView
            self.tableView = tableView
            syncSelection(in: tableView)
            return scrollView
        }

        func update(
            groups: [LibraryGroup],
            selectedGroupID: String?,
            isGroupUnlocked: @escaping (LibraryGroup) -> Bool,
            canManuallyLock: @escaping (LibraryGroup) -> Bool,
            canDeleteGroup: @escaping (LibraryGroup) -> Bool,
            onSelectGroup: @escaping (LibraryGroup) -> Void,
            onMove: @escaping (IndexSet, Int) -> Void,
            onLock: @escaping (LibraryGroup) -> Void,
            onRename: @escaping (LibraryGroup) -> Void,
            onDelete: @escaping (LibraryGroup) -> Void
        ) {
            let groupsChanged = self.groups.map(\.id) != groups.map(\.id)
                || self.groups.map(\.name) != groups.map(\.name)
            let unlockSnapshot = Set(groups.filter(isGroupUnlocked).map(\.id))
            let unlockChanged = unlockSnapshot != unlockedGroupIDs

            self.groups = groups
            self.selectedGroupID = selectedGroupID
            self.isGroupUnlocked = isGroupUnlocked
            self.canManuallyLock = canManuallyLock
            self.canDeleteGroup = canDeleteGroup
            self.onSelectGroup = onSelectGroup
            self.onMove = onMove
            self.onLock = onLock
            self.onRename = onRename
            self.onDelete = onDelete
            self.unlockedGroupIDs = unlockSnapshot

            guard let tableView else { return }
            if groupsChanged {
                tableView.reloadData()
            } else if unlockChanged {
                reloadVisibleCells(in: tableView)
            }
            syncSelection(in: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            groups.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard groups.indices.contains(row) else { return nil }
            let group = groups[row]
            let cell = tableView.makeView(
                withIdentifier: SidebarGroupCellView.reuseIdentifier,
                owner: self
            ) as? SidebarGroupCellView ?? SidebarGroupCellView()
            cell.configure(group: group, isUnlocked: isGroupUnlocked(group))
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SidebarSourceListRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView,
                  groups.indices.contains(tableView.selectedRow) else { return }
            onSelectGroup(groups[tableView.selectedRow])
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard groups.indices.contains(row) else { return nil }
            return groups[row].id as NSString
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            dropOperation == .on ? [] : .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard dropOperation == .above,
                  let draggedID = info.draggingPasteboard.string(forType: .string),
                  let sourceRow = groups.firstIndex(where: { $0.id == draggedID }) else {
                return false
            }

            var destination = row
            if sourceRow < row {
                destination -= 1
            }
            guard sourceRow != destination else { return true }

            onMove(IndexSet(integer: sourceRow), destination)
            return true
        }

        private func syncSelection(in tableView: NSTableView) {
            guard let selectedGroupID,
                  let row = groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }

            guard tableView.selectedRow != row else { return }

            isSyncingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func reloadVisibleCells(in tableView: NSTableView) {
            for row in tableView.rows(in: tableView.visibleRect).location ..< NSMaxRange(tableView.rows(in: tableView.visibleRect)) {
                guard groups.indices.contains(row),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarGroupCellView else {
                    continue
                }
                cell.configure(group: groups[row], isUnlocked: isGroupUnlocked(groups[row]))
            }
        }
    }
}

extension AppKitSidebarList.Coordinator: SidebarTableMenuDelegate {
    func sidebarTableView(_ tableView: SidebarTableView, menuFor event: NSEvent) -> NSMenu? {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard groups.indices.contains(row) else { return nil }

        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let group = groups[row]
        let menu = NSMenu()

        if canManuallyLock(group) {
            menu.addItem(menuItem(title: "上锁", action: #selector(lockGroupFromMenu(_:)), group: group))
            menu.addItem(.separator())
        }

        menu.addItem(menuItem(title: "重命名", action: #selector(renameGroupFromMenu(_:)), group: group))

        let deleteItem = menuItem(title: "删除", action: #selector(deleteGroupFromMenu(_:)), group: group)
        deleteItem.isEnabled = canDeleteGroup(group)
        menu.addItem(deleteItem)

        return menu
    }

    @objc private func lockGroupFromMenu(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LibraryGroup else { return }
        onLock(group)
    }

    @objc private func renameGroupFromMenu(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LibraryGroup else { return }
        onRename(group)
    }

    @objc private func deleteGroupFromMenu(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? LibraryGroup else { return }
        onDelete(group)
    }

    private func menuItem(title: String, action: Selector, group: LibraryGroup) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = group
        return item
    }
}

protocol SidebarTableMenuDelegate: AnyObject {
    func sidebarTableView(_ tableView: SidebarTableView, menuFor event: NSEvent) -> NSMenu?
}

final class SidebarTableView: NSTableView {
    weak var menuDelegate: SidebarTableMenuDelegate?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuDelegate?.sidebarTableView(self, menuFor: event)
    }
}

private final class SidebarSourceListRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { super.isEmphasized = false }
    }
}

private final class SidebarGroupCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarGroupCell")
    private static let horizontalInset: CGFloat = 6

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let statusView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        statusView.imageScaling = .scaleProportionallyDown
        statusView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(statusView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarGroupIconProvider.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: SidebarGroupIconProvider.iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: statusView.leadingAnchor, constant: -8),

            statusView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            statusView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusView.widthAnchor.constraint(equalToConstant: 16),
            statusView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(group: LibraryGroup, isUnlocked: Bool) {
        titleField.stringValue = group.name
        iconView.image = SidebarGroupIconProvider.icon(for: group.mediaType)
        iconView.contentTintColor = SidebarGroupIconProvider.iconColor(for: group.mediaType)

        if let status = SidebarGroupIconProvider.statusSymbol(for: group, isUnlocked: isUnlocked) {
            statusView.image = NSImage(
                systemSymbolName: status.name,
                accessibilityDescription: nil
            )
            statusView.contentTintColor = .secondaryLabelColor
            statusView.isHidden = false
        } else {
            statusView.image = nil
            statusView.isHidden = true
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let sidebarMainColumn = NSUserInterfaceItemIdentifier("SidebarMainColumn")
}
