import SwiftUI

struct CryptaToastView: View {
    let toast: CryptaToast

    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(toast.foregroundStyle)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .padding(.top, 12)
            .transition(.blurReplace)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
    }
}

private extension CryptaToast {
    var foregroundStyle: Color {
        switch kind {
        case .success: return .primary
        case .error: return Color(red: 0.82, green: 0.18, blue: 0.18)
        }
    }
}
