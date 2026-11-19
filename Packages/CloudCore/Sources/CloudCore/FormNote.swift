// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A problem in a form, said calmly: one short line under the field it's about, with the whole
/// explanation one click away. Both apps' forms show these, never a paragraph of red.
public struct FormNote: Equatable, Sendable {
    /// One short line, in the language shown.
    public var text: String
    /// Where it's shown.
    public var field: ConnectionFinding.Field
    /// The whole explanation, for Details.
    public var details: String?
    /// What the check found, step by step, for Details.
    public var steps: [ConnectionFinding.Step]

    public init(
        _ text: String, field: ConnectionFinding.Field = .server, details: String? = nil,
        steps: [ConnectionFinding.Step] = []
    ) {
        self.text = text
        self.field = field
        self.details = details
        self.steps = steps
    }

    /// A finding from checking why a server can't be reached.
    public init(_ finding: ConnectionFinding) {
        self.init(finding.short, field: finding.field, details: finding.sentence, steps: finding.steps)
    }

    /// A failure that reached the server, or never needed it, in its own words, under the field
    /// it's about.
    public static func forError(_ error: Error) -> FormNote {
        let text = error.localizedDescription
        switch error as? RemoteError {
        case .unauthorized?:
            return FormNote(text, field: .signIn)
        case .notFound(let path)? where path.isRoot:
            return FormNote(text, field: .folder)
        case .forbidden(let path)? where path.isRoot:
            return FormNote(text, field: .folder)
        default:
            return FormNote(text)
        }
    }
}

extension ConnectionChecks {
    /// A failure as a form shows it. An unreachable server is checked first, so the line says which
    /// part failed, and Details says the rest.
    public static func note(for error: Error, connection: Connection, device: DeviceKind) async -> FormNote {
        guard let finding = await finding(for: error, connection: connection, device: device) else {
            return .forError(error)
        }
        return FormNote(finding)
    }
}
