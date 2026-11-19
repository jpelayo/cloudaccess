// Apache 2 license - developer@infinitecontext.com

import CloudCore
import Testing

/// Once a form knows what's in the folder, the encryption switch shows only what's possible
/// there. A folder with plain files can't become encrypted, and an encrypted drive can only be
/// joined with its password.
@Suite struct EncryptionChoiceTests {
    @Test func plainFilesLockEncryptionOff() {
        let choice = EncryptionChoice.for(.plainFiles, device: .mac)
        #expect(choice.lockedValue == false)
        #expect(choice.reason == "This folder already has files that aren't encrypted, so it can't become an encrypted drive.")
    }

    @Test func aVaultLocksEncryptionOn() {
        for device in [DeviceKind.mac, .iPhone] {
            let choice = EncryptionChoice.for(.encryptedDrive, device: device)
            #expect(choice.lockedValue == true)
            #expect(choice.reason == "This folder is already an encrypted drive. Enter its encryption password to join it.")
        }
    }

    @Test func anEmptyFolderLeavesItFreeOnTheMac() {
        #expect(EncryptionChoice.for(.empty, device: .mac) == .free)
    }

    /// CloudWanderer only joins encrypted drives, so an empty folder can only be a plain one.
    @Test func anEmptyFolderLocksItOffOnTheIPhone() {
        let choice = EncryptionChoice.for(.empty, device: .iPhone)
        #expect(choice.lockedValue == false)
        #expect(choice.reason == "CloudWanderer only joins encrypted drives made with CloudAccess, and this folder isn't one.")
    }

    @Test func anUncheckedFolderLeavesItFree() {
        #expect(EncryptionChoice.for(nil, device: .mac) == .free)
        #expect(EncryptionChoice.for(nil, device: .iPhone) == .free)
        #expect(EncryptionChoice.free.lockedValue == nil)
        #expect(EncryptionChoice.free.reason == nil)
    }
}
