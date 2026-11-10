// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import os
import Synchronization
import UniformTypeIdentifiers

/// Debug-build tracing of what the extension tells macOS, read with `log show`. NSLog would
/// be redacted in a system-launched process, and this never runs in a release build.
public enum Trace {
    private struct Sink: Sendable {
        var logger: Logger
        var diagnostics: Diagnostics?
    }

    /// The Mac extension's, unless another extension says where its own go.
    private static let standard = Sink(
        logger: Logger(subsystem: "com.infinitecontext.CloudAccess", category: "extension"),
        diagnostics: try? DriveStore.shared().diagnostics)
    private static let chosen = Mutex<Sink?>(nil)

    private static var sink: Sink {
        chosen.withLock { $0 } ?? standard
    }

    /// Sends the trace somewhere other than the Mac extension's log. Call it before anything else.
    public static func use(subsystem: String, diagnostics: Diagnostics?) {
        chosen.withLock { $0 = Sink(logger: Logger(subsystem: subsystem, category: "extension"), diagnostics: diagnostics) }
    }

    public static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        sink.logger.notice("CA_EXT: \(text, privacy: .public)")
        #endif
    }

    /// What macOS really hands over for a package, which Apple doesn't document. No name, so it's
    /// safe to keep in a release build, and only for what could be one, so it stays quiet.
    public static func arrival(
        _ action: String, name: String, type: UTType?, options: UInt, contents: URL?
    ) {
        let isDirectory = (try? contents?.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let isFlattened = FlattenedPackage.isFlattened(name)
        guard isFlattened || isDirectory || type?.conforms(to: .package) == true else { return }
        let shape = contents == nil ? "none" : (isDirectory ? "folder" : "file")
        let kind = type?.identifier ?? "none"
        sink.logger.notice(
            "CM_ARRIVED: \(action, privacy: .public) flattened=\(isFlattened, privacy: .public) type=\(kind, privacy: .public) options=\(options, privacy: .public) contents=\(shape, privacy: .public)")
    }

    /// The kind of failure and nothing else, so it's safe to keep in a release build, where a
    /// failure otherwise leaves no trace. It goes to the log a person can open too, or that log
    /// would hold everything except what went wrong.
    public static func failure(_ action: String, _ error: Error, drive: String) {
        let kind = Diagnostics.kind(of: error)
        let sink = sink
        sink.logger.notice("CM_FAILED: \(action, privacy: .public) \(kind, privacy: .public)")
        sink.diagnostics?.record("\(drive): \(action) failed: \(kind)")
    }

    /// A file saved without its details, such as its own dates. The save stands, so this is only
    /// noted, with the engine's reason and no name.
    public static func detailsMissed(_ reason: String, drive: String) {
        let sink = sink
        sink.logger.notice("CM_DETAILS_MISSED: \(reason, privacy: .public)")
        sink.diagnostics?.record("\(drive): a file was saved without its details: \(reason)")
    }
}
