import AppKit
import SwiftUI

extension MediaType {
    var sidebarSymbolName: String {
        switch self {
        case .video: return "video.fill"
        case .image: return "photo.fill"
        }
    }

    var sidebarIconGradient: LinearGradient {
        switch self {
        case .video:
            return LinearGradient(
                colors: [
                    Color(red: 0.42, green: 0.74, blue: 0.94),
                    Color(red: 0.18, green: 0.46, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .image:
            return LinearGradient(
                colors: [
                    Color(red: 0.46, green: 0.82, blue: 0.50),
                    Color(red: 0.14, green: 0.62, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var professionalIconResourceName: String {
        switch self {
        case .video: return "video"
        case .image: return "image"
        }
    }

    var professionalIconColor: Color {
        switch self {
        case .video: return Color(red: 0.00, green: 0.48, blue: 1.00)
        case .image: return Color(red: 0.00, green: 0.60, blue: 0.32)
        }
    }
}

struct SidebarGroupLabel: View {
    let group: LibraryGroup
    let isUnlocked: Bool

    @Environment(\.sidebarIconTheme) private var theme
    @Environment(\.professionalSidebarIconSize) private var professionalIconSize

    var body: some View {
        Group {
            switch theme {
            case .professional:
                HStack(spacing: 8) {
                    Label {
                        Text(group.name)
                            .lineLimit(1)
                    } icon: {
                        ProfessionalSidebarGroupIcon(
                            mediaType: group.mediaType,
                            size: CGFloat(professionalIconSize + 3)
                        )
                    }

                    Spacer(minLength: 8)

                    statusIconView
                }
            case .colorful:
                HStack(spacing: 12) {
                    SidebarGroupCategoryIcon(mediaType: group.mediaType)

                    HStack {
                        Text(group.name)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        statusIconView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIconView: some View {
        if let descriptor = statusIconDescriptor {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .scaleEffect(descriptor.scale)
                .frame(width: 16, height: 16, alignment: .center)
        }
    }

    private var statusIconDescriptor: (systemImage: String, scale: CGFloat)? {
        switch group.encryptionLevel {
        case .standard:
            return nil
        case .extended:
            return (isUnlocked ? "lock.open.fill" : "lock.fill", 1)
        case .maximum:
            return (isUnlocked ? "lock.open.fill" : "lock.square.fill", 1)
        }
    }
}

private struct ProfessionalSidebarGroupIcon: View {
    let mediaType: MediaType
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.resourceImage(named: mediaType.professionalIconResourceName) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: mediaType.sidebarSymbolName)
                    .font(.system(size: size - 2, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
            }
        }
        .foregroundStyle(mediaType.professionalIconColor)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func resourceImage(named name: String) -> NSImage? {
        let resourceURLs = [
            Bundle.main.resourceURL?.appendingPathComponent("\(name).svg"),
            Bundle.main.resourceURL?.appendingPathComponent("SidebarIcons/\(name).svg"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/SidebarIcons/\(name).svg")
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

private struct SidebarGroupCategoryIcon: View {
    let mediaType: MediaType

    @Environment(\.sidebarIconTileSize) private var tileSize
    @Environment(\.sidebarIconSymbolSize) private var symbolSize
    @Environment(\.sidebarIconCornerRadius) private var cornerRadius

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(mediaType.sidebarIconGradient)

            Image(systemName: mediaType.sidebarSymbolName)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
        .frame(width: tileSize, height: tileSize)
    }
}

private struct SidebarIconThemeKey: EnvironmentKey {
    static let defaultValue: SidebarIconTheme = .colorful
}

private struct SidebarIconTileSizeKey: EnvironmentKey {
    static let defaultValue: Double = 22
}

private struct SidebarIconSymbolSizeKey: EnvironmentKey {
    static let defaultValue: Double = 11
}

private struct SidebarIconCornerRadiusKey: EnvironmentKey {
    static let defaultValue: Double = 6
}

private struct ProfessionalSidebarIconSizeKey: EnvironmentKey {
    static let defaultValue: Double = 15
}

extension EnvironmentValues {
    var sidebarIconTheme: SidebarIconTheme {
        get { self[SidebarIconThemeKey.self] }
        set { self[SidebarIconThemeKey.self] = newValue }
    }

    var sidebarIconTileSize: Double {
        get { self[SidebarIconTileSizeKey.self] }
        set { self[SidebarIconTileSizeKey.self] = newValue }
    }

    var sidebarIconSymbolSize: Double {
        get { self[SidebarIconSymbolSizeKey.self] }
        set { self[SidebarIconSymbolSizeKey.self] = newValue }
    }

    var sidebarIconCornerRadius: Double {
        get { self[SidebarIconCornerRadiusKey.self] }
        set { self[SidebarIconCornerRadiusKey.self] = newValue }
    }

    var professionalSidebarIconSize: Double {
        get { self[ProfessionalSidebarIconSizeKey.self] }
        set { self[ProfessionalSidebarIconSizeKey.self] = newValue }
    }
}
