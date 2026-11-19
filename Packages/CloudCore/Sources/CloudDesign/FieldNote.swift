// Apache 2 license - developer@infinitecontext.com

import SwiftUI

/// A problem in a form, said calmly: one short line under the field it's about, with an orange
/// mark, and the whole explanation one click away. Never red, and never a paragraph: red is kept
/// for what can't be undone, and a long alarm under a form helps nobody fix it.
public struct FieldNote: View {
    let text: String
    let details: String?
    let steps: [(title: String, result: String)]
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?

    @State private var showsDetails = false

    /// - Parameters:
    ///   - text: One short line, already in the language shown.
    ///   - details: The whole explanation, shown under Details.
    ///   - steps: What a check found, step by step, shown under Details.
    ///   - actionTitle: A button that mends it, such as using a server's new address.
    public init(
        _ text: String, details: String? = nil, steps: [(title: String, result: String)] = [],
        actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil
    ) {
        self.text = text
        self.details = details
        self.steps = steps
        self.actionTitle = actionTitle
        self.action = action
    }

    private var hasDetails: Bool {
        details != nil || !steps.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.pill)
                }
            }
            .font(.caption)
            if hasDetails {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let details {
                            Text(verbatim: details)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(verbatim: "\(step.title): \(step.result)")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }
}
