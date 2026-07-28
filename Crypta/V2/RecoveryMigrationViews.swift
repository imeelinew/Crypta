import SwiftUI

struct RecoveryKeySheet: View {
    let presentation: RecoveryKeyPresentation
    let onCopy: () -> Void
    let onSave: () -> Void
    let onConfirm: () -> Void

    @State private var isConfirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ApprovedCopy.recoveryIntroTitle)
                    .font(.title2.weight(.semibold))
                Text(ApprovedCopy.recoveryIntroMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(presentation.recoveryKey.description)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(presentation.recoveryKey.description)

            HStack {
                Button(ApprovedCopy.recoveryCopyButton, action: onCopy)
                Button(ApprovedCopy.recoverySaveButton, action: onSave)
            }

            Toggle(
                ApprovedCopy.recoveryConfirmLabel,
                isOn: $isConfirmed
            )
            .onChange(of: isConfirmed) { _, confirmed in
                guard confirmed else { return }
                onConfirm()
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}

struct RecoveryAccessSheet: View {
    @Bindable var library: CryptaLibrary
    let presentation: RecoveryAccessPresentation

    @State private var phrase = ""
    @State private var attemptResult: RecoveryAccessAttemptResult?
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ApprovedCopy.recoveryAccessTitle)
                    .font(.title2.weight(.semibold))
                Text(ApprovedCopy.recoveryAccessMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField(ApprovedCopy.recoveryAccessField, text: $phrase)
                .textFieldStyle(.roundedBorder)
                .focused($fieldIsFocused)
                .onSubmit(submit)
                .onChange(of: phrase) {
                    attemptResult = nil
                }

            if let feedback {
                Label(feedback, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if library.isRecoveringAccess {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(ApprovedCopy.recoveryAccessButton, action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        phrase.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || library.isRecoveringAccess
                    )
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(
            library.isRecoveryAccessRequired || library.isRecoveringAccess
        )
        .onAppear {
            fieldIsFocused = true
        }
    }

    private var feedback: String? {
        switch attemptResult {
        case .invalidKey:
            ApprovedCopy.recoveryAccessInvalid
        case .failure:
            ApprovedCopy.recoveryAccessFailure
        case .success, .none:
            nil
        }
    }

    private func submit() {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !library.isRecoveringAccess else {
            return
        }
        let submittedPhrase = phrase
        Task {
            let result = await library.recoverAccess(
                phrase: submittedPhrase,
                presentation: presentation
            )
            attemptResult = result
            if result == .success {
                phrase = ""
            }
        }
    }
}

struct MigrationSheet: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ApprovedCopy.migrationTitle)
                    .font(.title2.weight(.semibold))
                Text(ApprovedCopy.migrationMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch library.migrationPresentationState {
            case .ready:
                Button(ApprovedCopy.migrationStartButton) {
                    Task { await library.startMigration() }
                }
                .buttonStyle(.borderedProminent)

            case .running:
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(
                        value: Double(library.migrationProgress.completedCount),
                        total: Double(max(library.migrationProgress.totalCount, 1))
                    )
                    Text(
                        ApprovedCopy.migrationProgress(
                            current: currentItem,
                            total: library.migrationProgress.totalCount
                        )
                    )
                    .foregroundStyle(.secondary)
                }

            case .complete:
                Label(
                    ApprovedCopy.migrationComplete,
                    systemImage: "checkmark.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(.green)

            case .failed:
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        ApprovedCopy.migrationFailureMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(ApprovedCopy.migrationStartButton) {
                        Task { await library.startMigration() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private var currentItem: Int {
        let total = library.migrationProgress.totalCount
        guard total > 0 else { return 0 }
        return min(library.migrationProgress.completedCount + 1, total)
    }
}
