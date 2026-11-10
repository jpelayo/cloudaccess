// Apache 2 license - developer@infinitecontext.com

import Foundation

/// A long random passphrase. A password handed around by hand is only as strong as what
/// people type, so the app offers one that doesn't depend on that.
public enum Passphrase {
    /// No characters that look alike, so it survives being read aloud or copied by hand.
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// Six groups of five, about 148 bits of randomness.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<6).map { _ in
            String((0..<5).map { _ in alphabet.randomElement(using: &generator)! })
        }.joined(separator: "-")
    }
}

/// What a person keeps safe to reach an encrypted drive without this app.
public struct RecoveryKit: Sendable {
    public var driveName: String
    public var address: String
    public var password: String
    public var salt: String
    public var vaultID: String

    public init(driveName: String, address: String, password: String, salt: String, vaultID: String) {
        self.driveName = driveName
        self.address = address
        self.password = password
        self.salt = salt
        self.vaultID = vaultID
    }

    /// The kit as text to save or print, in the language shown, because it's for a person to read.
    /// The rclone settings stay as they are: rclone reads them in one language only.
    public var text: String {
        """
        \(Words.text("CloudAccess recovery kit"))
        \(Words.text("Keep this somewhere safe. Anyone with it can read this drive."))

        \(Words.format("Drive: %@", driveName))
        \(Words.format("Address: %@", address))
        \(Words.format("Vault ID: %@", vaultID))

        \(Words.format("Encryption password: %@", password))
        \(Words.format("Salt: %@", salt))

        \(Words.text("To reach your files with plain rclone (https://rclone.org), run `rclone config`,\nor add this to rclone.conf. First obscure both values with `rclone obscure`:"))

        [cloudaccess-recovery]
        type = crypt
        remote = <your server's rclone remote>:<the drive's folder>
        filename_encryption = standard
        directory_name_encryption = true
        filename_encoding = base32
        password = <obscured encryption password>
        password2 = <obscured salt>

        \(Words.text("Then: rclone copy cloudaccess-recovery: /a/local/folder"))

        \(Words.text("The .cloudmount folder on the server isn't part of your files, and rclone\nskips it with a notice."))
        """
    }
}
