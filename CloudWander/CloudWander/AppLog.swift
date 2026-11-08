// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Foundation
import UIKit

/// What the app writes to the log a person can read in About, beside what the Files extension
/// writes. Drive names, never file names, in every build.
enum AppLog {
    /// When the app last went into the background. iOS stops a download then, and that isn't a
    /// fault, so a failure after it says so.
    private(set) static var lastLeft: Date?
    private static var observer: NSObjectProtocol?

    /// The app's version and build, as the log and its export give them.
    static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        return "CloudWander \(version) (\(build)), iOS \(UIDevice.current.systemVersion)"
    }

    /// Once, at launch.
    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { lastLeft = Date() }
        }
        record("Started: \(versionLine)")
        let moves = PhoneDrives.passwordMoves.values
        let moved = moves.filter { $0 == .moved }.count
        let kept = moves.filter { $0 == .keptWhereItWas }.count
        if moved > 0 || kept > 0 {
            record("Passwords moved where Files can read them: \(moved), not moved yet: \(kept)")
        }
    }

    /// Writes off the main thread, stamped with when it happened.
    static func record(_ message: String) {
        let diagnostics = PhoneDrives.store.diagnostics
        let now = Date()
        Task.detached(priority: .utility) {
            diagnostics.record(message, now: now)
        }
    }

    /// One line for a download that finished, failed or was cancelled, with where the time went.
    static func download(on connection: Connection, progress: DownloadProgress, started: Date, error: Error?) {
        var facts: [String] = []
        if let total = progress.total {
            // How far it got says more than the error alone: nothing at all, or most of it.
            facts.append(error == nil ? size(total) : "\(size(progress.bytes)) of \(size(total))")
        }
        facts.append(progress.timings())
        if connection.isEncrypted {
            facts.append("encrypted")
        }
        if error != nil, let lastLeft, lastLeft > started {
            facts.append("CloudWander went into the background during it")
        }
        let outcome: String
        switch error {
        case nil: outcome = "download finished"
        case is CancellationError: outcome = "download cancelled"
        case let error?: outcome = "download failed: \(Diagnostics.kind(of: error))"
        }
        record("\(connection.displayName): \(outcome), \(facts.joined(separator: ", "))")
    }

    private static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
