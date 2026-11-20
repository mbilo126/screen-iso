import AppKit
import ScreenISOCore
import SwiftUI

struct PanelView: View {
    static let width: CGFloat = 400
    static let minHeight: CGFloat = 280
    static let idealHeight: CGFloat = 340
    static let maxHeight: CGFloat = 720

    let model: AppModel
    @State private var contentHeight = PanelView.idealHeight

    var body: some View {
        ScrollView {
            PanelContent(model: model)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .frame(width: Self.width)
        // A ScrollView has no height of its own: the ideal height follows the content, so the menu bar panel
        // neither collapses nor scrolls while the content fits on screen.
        .frame(
            minHeight: Self.minHeight,
            idealHeight: min(max(contentHeight, Self.minHeight), Self.maxHeight),
            maxHeight: Self.maxHeight
        )
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        Task { await model.refreshStatus() }
    }
}

struct PanelContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let busy = model.busyAction {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busy)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.displayedError {
                NoticeLine(kind: .error, text: error.message)
            }
            systemContent
            Divider()
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            Text("ScreenISO")
                .font(.title3.bold())
            Spacer()
            if model.isLoadingStatus {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Aggiorna lo stato")
            }
        }
    }

    @ViewBuilder
    private var systemContent: some View {
        if let status = model.status {
            if let error = model.statusError {
                StatusErrorView(error: error, retry: refresh)
            }
            ActivitySection(model: model, status: status)
            Divider()
            LockSection(model: model, status: status)
        } else if let error = model.statusError {
            StatusErrorView(error: error, retry: refresh)
        } else {
            StatusLoadingView()
        }
    }

    private var footer: some View {
        HStack {
            Button("Apri registro") { model.openAuditLog() }
            if model.status?.sudoRuleInstalled == true {
                Button("Rimuovi regola sudoers") {
                    Task { await model.removeSudoRule() }
                }
                .disabled(model.isBusy)
            }
            Spacer()
            Button("Esci") { model.quit() }
                .disabled(model.isBusy)
        }
    }

    private func refresh() {
        Task { await model.refreshStatus() }
    }
}

private struct StatusLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 14)
            }
            Text("Lettura dello stato del sistema")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lettura dello stato del sistema")
    }
}

private struct StatusErrorView: View {
    let error: DisplayedError
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeLine(kind: .error, text: "Lettura dello stato non riuscita. \(error.message)")
            Button("Riprova", action: retry)
        }
    }
}

private struct ActivitySection: View {
    let model: AppModel
    let status: SystemStatus

    var body: some View {
        PanelSection(title: "Attività") {
            HStack(spacing: 6) {
                Text("caffeinate")
                    .font(.system(.body, design: .monospaced))
                    .fixedSize()
                ForEach(PowerAssertionKind.allCases, id: \.self) { kind in
                    Toggle(
                        isOn: Binding(
                            get: { model.isAssertionActive(kind) },
                            set: { model.setAssertion(kind, active: $0) }
                        )
                    ) {
                        Text(kind.caffeinateFlag)
                            .font(.system(.body, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .help(Labels.title(of: kind))
                    .accessibilityLabel(Labels.title(of: kind))
                }
                Spacer(minLength: 0)
                Toggle(
                    Labels.allAssertionsTitle,
                    isOn: Binding(
                        get: { model.areAllAssertionsActive },
                        set: { model.setAllAssertions(active: $0) }
                    )
                )
                .toggleStyle(.checkbox)
                .help(Labels.allAssertionsHelp)
                .accessibilityLabel(Labels.allAssertionsHelp)
            }
            HStack {
                Text("SleepDisabled")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Toggle(
                    "SleepDisabled",
                    isOn: Binding(
                        get: { model.pendingSleepDisabled ?? status.sleepDisabled },
                        set: { value in Task { await model.setSleepDisabled(value) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!status.sudoRuleInstalled)
                .help(Labels.sleepDisabledHelp)
            }
            sudoRuleNotice
            Text(
                "Restano attive finché non le disattivi, anche a schermo bloccato. Le opzioni di caffeinate valgono finché l'app è aperta."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private var sudoRuleNotice: some View {
        if !status.sudoRuleInstalled {
            if status.sleepDisabled {
                NoticeLine(
                    kind: .warning,
                    text: "SleepDisabled è attivo e senza la regola sudoers si disattiva solo dal Terminale."
                )
                CommandSnippet(command: Labels.restoreSleepCommand, copy: model.copyToPasteboard)
            }
            Text(
                "Per cambiare SleepDisabled serve una regola sudoers che consente solo pmset -a disablesleep 0 e 1 senza password."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Installa regola") {
                Task { await model.installSudoRule() }
            }
        }
    }
}

private struct LockSection: View {
    let model: AppModel
    let status: SystemStatus

    var body: some View {
        PanelSection(title: "Blocco") {
            HStack(spacing: 8) {
                ForEach(LockMode.allCases, id: \.self) { mode in
                    Button {
                        Task { await model.lock(mode) }
                    } label: {
                        Text(Labels.title(of: mode))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.lockBlockingReason(mode) != nil)
                }
            }
            if !status.screenLockCompliant {
                NoticeLine(
                    kind: .warning,
                    text:
                        "macOS non chiede la password subito dopo il blocco (impostazione attuale: \(Labels.description(of: status.screenLockPolicy))). ScreenISO non cambia questa impostazione: eseguila nel Terminale."
                )
                CommandSnippet(command: Labels.screenLockFixCommand, copy: model.copyToPasteboard)
            }
            if !status.lockSymbolResolvable {
                NoticeLine(kind: .error, text: "La funzione di blocco di macOS non è disponibile.")
            }
            if status.screenSaverInstalled {
                installedSaver
            } else {
                Text("Il salvaschermo ScreenISO non è installato.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Installa salvaschermo") {
                    Task { await model.installScreenSaver() }
                }
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private var installedSaver: some View {
        if model.saverNeedsUpdate {
            NoticeLine(
                kind: .warning,
                text: "Il salvaschermo installato è diverso da quello incluso in questa versione dell'app."
            )
            Button("Aggiorna salvaschermo") {
                Task { await model.updateScreenSaver() }
            }
        }
        if !status.screenSaverSelected {
            NoticeLine(
                kind: .warning,
                text:
                    "È selezionato un altro salvaschermo: il pulsante Salvaschermo mostrerà quello. "
                    + model.screenSaverSettingsPane.selectionHint
            )
            Button(model.screenSaverSettingsPane.openButtonTitle) {
                model.openScreenSaverSettings()
            }
        }
    }
}
