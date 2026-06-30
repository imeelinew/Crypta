import AppKit
import SwiftUI

extension MediaType {
    var professionalSymbolName: String {
        switch self {
        case .video: return "video.fill"
        case .image: return "photo.fill"
        }
    }

    var professionalIconResourceName: String {
        switch self {
        case .video: return "video"
        case .image: return "image"
        }
    }
}

enum SidebarGroupIconProvider {
    static let iconSize: CGFloat = 18

    static func icon(for mediaType: MediaType) -> NSImage {
        if let image = resourceImage(named: mediaType.professionalIconResourceName) {
            return image
        }
        return NSImage(
            systemSymbolName: mediaType.professionalSymbolName,
            accessibilityDescription: nil
        ) ?? NSImage(size: NSSize(width: iconSize, height: iconSize))
    }

    static func iconColor(for mediaType: MediaType) -> NSColor {
        switch mediaType {
        case .video:
            return NSColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1)
        case .image:
            return NSColor(red: 0.00, green: 0.60, blue: 0.32, alpha: 1)
        }
    }

    static func statusSymbol(for group: LibraryGroup, isUnlocked: Bool) -> (name: String, scale: CGFloat)? {
        switch group.encryptionLevel {
        case .standard:
            return nil
        case .extended:
            return (isUnlocked ? "lock.open.fill" : "lock.fill", 1)
        case .maximum:
            return (isUnlocked ? "lock.open.fill" : "lock.square.fill", 1)
        }
    }

    private static func resourceImage(named name: String) -> NSImage? {
        let resourceURLs = [
            Bundle.main.resourceURL?.appendingPathComponent("\(name).svg"),
            Bundle.main.resourceURL?.appendingPathComponent("SidebarIcons/\(name).svg"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/SidebarIcons/\(name).svg"),
        ]

        for url in resourceURLs.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                let copy = image.copy() as? NSImage ?? image
                copy.isTemplate = true
                return copy
            }
        }

        return nil
    }
}
