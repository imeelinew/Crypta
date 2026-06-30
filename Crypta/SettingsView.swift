import SwiftUI

struct CryptaSettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem {
                    Label("外观", systemImage: "paintpalette")
                }

            SubtitleSettingsView()
                .tabItem {
                    Label("字幕", systemImage: "captions.bubble")
                }
        }
        .frame(width: 488, height: 384)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(SidebarIconTheme.storageKey) private var sidebarIconThemeRaw = SidebarIconTheme.colorful.rawValue

    private var sidebarIconThemeBinding: Binding<SidebarIconTheme> {
        Binding(
            get: { SidebarIconTheme(rawValue: sidebarIconThemeRaw) ?? .colorful },
            set: { sidebarIconThemeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("侧边栏图标", selection: sidebarIconThemeBinding) {
                ForEach(SidebarIconTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 18)
    }
}

private struct SubtitleSettingsView: View {
    @State private var settings = SubtitleSettingsStore.live.load()
    @State private var toast: CryptaToast?
    @State private var isTestingConnection = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Whisper 模型", text: $settings.whisperModelPath)
                SecureField("API 密钥", text: $settings.apiKey)
                TextField("服务地址", text: $settings.baseURLString)
                TextField("模型", text: $settings.model)
                Toggle("智能分句", isOn: $settings.segmentationEnabled)
                Toggle("翻译字幕", isOn: $settings.translationEnabled)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("测试连接") {
                    testConnection()
                }
                .disabled(isTestingConnection)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .padding(.top, 18)
        .overlay(alignment: .top) {
            toastView
        }
        .onChange(of: settings) { _, _ in
            save()
        }
        .task(id: toast) {
            guard let currentToast = toast else { return }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard toast == currentToast else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    toast = nil
                }
            }
        }
    }

    private func save() {
        do {
            try SubtitleSettingsStore.live.save(settings)
        } catch {
            toast = CryptaToast(message: error.localizedDescription, kind: .error)
        }
    }

    private func testConnection() {
        save()
        isTestingConnection = true
        let configuration = SubtitleConfiguration(settings: settings)
        Task {
            do {
                _ = try await SubtitleLLMClient.requestJSON(
                    configuration: configuration,
                    systemPrompt: #"Return only JSON: {"ok":true}."#,
                    userPayload: ["test": "connection"],
                    maxTokens: 64,
                    title: "Crypta Subtitle Settings Connection Test"
                )
                await MainActor.run {
                    toast = CryptaToast(message: "连接成功", kind: .success)
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    toast = CryptaToast(message: error.localizedDescription, kind: .error)
                    isTestingConnection = false
                }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
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
}

private extension CryptaToast {
    var foregroundStyle: Color {
        switch kind {
        case .success: return .primary
        case .error: return Color(red: 0.82, green: 0.18, blue: 0.18)
        }
    }
}
