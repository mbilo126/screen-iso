import SwiftUI

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum RequirementState {
    case satisfied
    case missing
    case informative(Bool)
}

struct RequirementRow<Detail: View>: View {
    let title: String
    let state: RequirementState
    let value: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                detail
            }
        }
    }

    private var symbol: String {
        switch state {
        case .satisfied: "checkmark.circle.fill"
        case .missing: "xmark.circle.fill"
        case .informative: "info.circle"
        }
    }
}

extension RequirementRow where Detail == EmptyView {
    init(title: String, state: RequirementState, value: String) {
        self.init(title: title, state: state, value: value) { EmptyView() }
    }
}

struct NoticeLine: View {
    enum Kind {
        case error
        case warning
        case info
    }

    let kind: Kind
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
        }
        .font(.callout)
    }

    private var symbol: String {
        switch kind {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }
}

struct CommandSnippet: View {
    let command: String
    let copy: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Button("Copia comando") { copy(command) }
                .controlSize(.small)
        }
    }
}
