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

    /// The kit as text to save or print.
    public var text: String {
        """
        CloudAccess recovery kit
        Keep this somewhere safe. Anyone with it can read this drive.

        Drive: \(driveName)
        Address: \(address)
        Vault ID: \(vaultID)

        Encryption password: \(password)
        Salt: \(salt)

        To reach your files with plain rclone (https://rclone.org), run `rclone config`,
        or add this to rclone.conf. First obscure both values with `rclone obscure`:

        [cloudaccess-recovery]
        type = crypt
        remote = <your server's rclone remote>:<the drive's folder>
        filename_encryption = standard
        directory_name_encryption = true
        filename_encoding = base32
        password = <obscured encryption password>
        password2 = <obscured salt>

        Then: rclone copy cloudaccess-recovery: /a/local/folder

        The .cloudmount folder on the server isn't part of your files, and rclone
        skips it with a notice.
        """
    }
}
