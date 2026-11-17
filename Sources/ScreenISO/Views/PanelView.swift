import AppKit
import ScreenISOCore
import SwiftUI

struct PanelView: View {
    static let width: CGFloat = 400
    static let minHeight: CGFloat = 360
    static let idealHeight: CGFloat = 680
    static let maxHeight: CGFloat = 720

    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                StatusSection(model: model)
                Divider()
                systemContent
                Divider()
                SessionButton(model: model)
                Divider()
                footer
            }
            .padding(16)
        }
        .frame(width: Self.width)
        // A ScrollView has no height of its own: without an ideal height the menu bar panel could collapse.
        .frame(minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: Self.maxHeight)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
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
            RequirementsSection(status: status, copy: model.copyToPasteboard)
            Divider()
            PowerSection(model: model, status: status)
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
            Spacer()
            Button("Esci") {
                Task { await model.quit() }
            }
            .disabled(model.isBusy)
        }
    }

    private func refresh() {
        Task { await model.refreshStatus() }
    }
}

private struct StatusSection: View {
    let model: AppModel

    var body: some View {
        PanelSection(title: "Stato") {
            Text(phaseText)
            if let notice = model.recoveredNotice {
                NoticeLine(kind: .info, text: notice)
            }
            if let error = model.sessionError {
                NoticeLine(kind: .error, text: error.message)
            }
            if let error = model.actionError {
                NoticeLine(kind: .error, text: error.message)
            }
            if let error = model.recoveryError {
                NoticeLine(kind: .error, text: error.message)
                Button("Riprova") {
                    Task {
                        await model.recover()
                        await model.refreshStatus()
                    }
                }
            }
            if let error = model.corruptedSnapshot {
                NoticeLine(kind: .error, text: error.message)
                Text(
                    "Il file non viene scartato in automatico. Scartarlo non ripristina lo stop se la sessione interrotta lo aveva disattivato: controlla SleepDisabled qui sotto."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Scarta stato salvato") {
                    Task { await model.discardSnapshot() }
                }
            }
        }
    }

    private var phaseText: String {
        switch model.controller.phase {
        case .idle: "Pronto"
        case .starting: "Avvio della sessione in corso"
        case .active(let session): "Sessione attiva dalle \(Labels.clockTime(session.startedAt))"
        case .ending: "Chiusura della sessione in corso"
        }
    }
}

private struct StatusLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
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

private struct RequirementsSection: View {
    let status: SystemStatus
    let copy: (String) -> Void

    var body: some View {
        PanelSection(title: "Requisiti") {
            RequirementRow(
                title: "Password richiesta subito al blocco",
                state: status.screenLockCompliant ? .satisfied : .missing,
                value: status.screenLockCompliant ? "Conforme" : Labels.description(of: status.screenLockPolicy)
            ) {
                if !status.screenLockCompliant {
                    Text("ScreenISO non cambia questa impostazione. Eseguila nel Terminale:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    CommandSnippet(command: Labels.screenLockFixCommand, copy: copy)
                }
            }
            RequirementRow(
                title: "Touch ID",
                state: .informative(status.touchIDAvailable),
                value: status.touchIDAvailable ? "Disponibile" : "Non disponibile"
            )
            RequirementRow(
                title: "Funzione di blocco",
                state: status.lockSymbolResolvable ? .satisfied : .missing,
                value: status.lockSymbolResolvable ? "Disponibile" : "Non disponibile"
            )
        }
    }
}

private struct PowerSection: View {
    let model: AppModel
    let status: SystemStatus

    var body: some View {
        PanelSection(title: "Alimentazione") {
            ForEach(PowerAssertionKind.allCases, id: \.self) { kind in
                Toggle(
                    Labels.title(of: kind),
                    isOn: Binding(
                        get: { model.isPowerAssertionEnabled(kind) },
                        set: { model.setPowerAssertion(kind, enabled: $0) }
                    )
                )
            }
            Toggle(
                "Durante la sessione resta sveglio a coperchio chiuso (pmset disablesleep)",
                isOn: Binding(
                    get: { model.configuration.keepAwakeWithLidClosed },
                    set: { model.setKeepAwakeWithLidClosed($0) }
                )
            )
            sleepDisabledControl
            sudoRule
        }
        .disabled(model.isSessionRunning || model.isBusy)
    }

    @ViewBuilder
    private var sudoRule: some View {
        if status.sudoRuleInstalled {
            HStack {
                Text("Regola sudoers installata")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rimuovi regola") {
                    Task { await model.removeSudoRule() }
                }
            }
        } else {
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

    @ViewBuilder
    private var sleepDisabledControl: some View {
        Toggle(
            "SleepDisabled attivo adesso, anche fuori sessione",
            isOn: Binding(
                get: { model.pendingSleepDisabled ?? status.sleepDisabled },
                set: { value in Task { await model.setSleepDisabled(value) } }
            )
        )
        .disabled(!status.sudoRuleInstalled)
        if status.sleepDisabled && !model.isSessionRunning {
            if status.sudoRuleInstalled {
                NoticeLine(
                    kind: .warning,
                    text:
                        "Lo stop è disattivato finché non spegni questo interruttore: il Mac non va in stop nemmeno a coperchio chiuso."
                )
            } else {
                NoticeLine(
                    kind: .warning,
                    text:
                        "Lo stop è disattivato in modo permanente: il Mac non va in stop nemmeno a coperchio chiuso. Senza la regola sudoers si riattiva dal Terminale."
                )
                CommandSnippet(command: Labels.restoreSleepCommand, copy: model.copyToPasteboard)
            }
        }
    }
}

private struct LockSection: View {
    let model: AppModel
    let status: SystemStatus

    var body: some View {
        PanelSection(title: "Blocco") {
            Picker(
                "Modalità di blocco",
                selection: Binding(
                    get: { model.configuration.lockMode },
                    set: { model.setLockMode($0) }
                )
            ) {
                ForEach(LockMode.allCases, id: \.self) { mode in
                    Text(Labels.title(of: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
        .disabled(model.isSessionRunning || model.isBusy)
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
        if status.screenSaverSelected {
            if model.configuration.lockMode == .screenSaver {
                NoticeLine(kind: .info, text: "Il salvaschermo ScreenISO è selezionato nelle Impostazioni di Sistema.")
            }
        } else if model.saverJustInstalled || model.configuration.lockMode == .screenSaver {
            NoticeLine(
                kind: .warning,
                text:
                    "È selezionato un altro salvaschermo: la sessione mostrerà quello. "
                    + model.screenSaverSettingsPane.selectionHint
            )
            Button(model.screenSaverSettingsPane.openButtonTitle) {
                model.openScreenSaverSettings()
            }
        }
    }
}

private struct SessionButton: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let busy = model.busyAction {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busy)
                        .foregroundStyle(.secondary)
                }
            } else if case .active = model.controller.phase {
                Button("Termina sessione") {
                    Task { await model.endSession() }
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await model.startSession() }
                } label: {
                    Text("Avvia sessione protetta")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.startBlockingReason != nil || model.isSessionRunning)
                if let reason = model.startBlockingReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
