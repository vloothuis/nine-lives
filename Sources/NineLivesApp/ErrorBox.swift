import SwiftUI
import NineLivesCore

/// A short message for people, with the technical output on request.
struct ShownError: Equatable {
    var summary: String
    var details: String?

    init(_ summary: String, details: String? = nil) {
        self.summary = summary
        self.details = details
    }

    init(_ error: Error) {
        self.init(error.localizedDescription, details: BackupCoordinator.details(error))
    }
}

struct ErrorBox: View {
    let error: ShownError
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.summary, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.callout)
            if let details = error.details {
                HStack(spacing: 10) {
                    Button(expanded ? "Hide Details" : "Show Details") { expanded.toggle() }
                    Button("Copy") { copy(details) }
                }
                .buttonStyle(.link).font(.caption)
                if expanded {
                    ScrollView {
                        Text(details).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120).padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(error.summary)\n\n\(text)", forType: .string)
    }
}
