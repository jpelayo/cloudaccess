<p align="center">
  <img src="CloudAccess/CloudAccess/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="CloudAccess icon">
</p>

<h1 align="center">CloudAccess</h1>

<p align="center">
  Your own storage, as a drive on your Mac.<br>
  With <b>CloudWanderer</b>, the same files on your iPhone.
</p>

> **Attention: in development.** Don't keep the only copy of anything on it yet.

## What is it?

You may already pay for storage, such as a storage box from a hosting company, a storage device at home (a NAS), or space on a web server. Getting files in and out of it usually means a separate program, copying files back and forth, and keeping track of which copy is the latest.

**CloudAccess makes that storage an ordinary drive on your Mac.** It appears in Finder's sidebar, like iCloud Drive or Dropbox. You open, save, rename and move files as usual, and they're kept on your storage.

- **It doesn't fill your Mac.** Files stay on your storage and download when you open them. Copies you haven't used for a while are removed from the Mac and remain on the storage.
- **You choose what stays.** Mark a folder to keep it downloaded, and it's available even without internet.
- **It can encrypt your files.** With encryption on, files are encrypted on your Mac before they leave it. Whoever runs the storage sees unreadable data, not your files or their names.
- **It doesn't lose your work.** Once your Mac confirms a save, the save is kept. If two computers change the same file at the same time, both versions are kept. Deleted files stay in a trash on the storage for a week, unless you choose otherwise. This is Safe mode, the default. See [Drive modes](#drive-modes).
- **Your drives move with you.** One encrypted file takes your drives and their passwords to another Mac or an iPhone, by AirDrop.
- **Nothing locks you in.** Files are stored in standard formats, so other tools can always read them, even without this app.

**CloudWanderer** is the iPhone companion. It lets you browse your drives, download files and share them to other apps. Plain drives also appear in the iPhone's Files app. To set it up, you scan a code on your Mac and type only the passwords.

Both apps are in English and Spanish.

### What you need

- A Mac with macOS 26 or later. CloudWanderer needs an iPhone with iOS 26 or later.
- Storage you can reach over **WebDAV** or **SFTP**, two common ways for apps to connect to storage. Your provider or device tells you which one it offers, along with an address, a username and a password.

It has been tested with a Hetzner Storage Box and with test servers. Other storage has to pass the same safety checks. If a drive can't be written to safely, it opens read-only.

There's no download yet. For now, build it from source, as described in [For developers](#for-developers).

## Getting started

### On your Mac

1. Click the CloudAccess icon in the menu bar, choose Settings, then choose Add Drive.
2. Enter your storage's address, username and password. Turn on **Enable encryption** if you want it. You can't change this later.
3. Turn CloudAccess on in System Settings, under General, Login Items & Extensions. The CloudAccess menu has a shortcut to it.
4. The drive appears in Finder's sidebar.

In a drive's details, you choose how long downloaded copies stay, how much space they can use, and which folders stay downloaded.

To start CloudAccess when you log in, turn on **Launch at login** in Settings.

### On your iPhone

1. On your Mac, open the drive's details and choose Show QR Code.
2. In CloudWanderer, add a drive, scan the code and type the passwords.

To change a drive later, swipe it and choose Edit. To add several drives at once, passwords included, use a drives file.

### Moving drives to another Mac or iPhone

1. **Export.** On the Mac, open Settings and choose Export… in the Export drives row. In CloudWanderer, use the Drives file section. The device first asks for Touch ID, Face ID or its password.
2. **Choose and seal.** Pick the drives to include. The file is sealed with its own password. Use the one offered, or your own of at least 12 characters.
3. **Send it** with AirDrop, or save it.
4. **Import.** On another Mac, choose Import… in the Import drives row in Settings. On an iPhone, open the file from AirDrop in CloudWanderer.
5. **Enter the file's password,** then choose what happens to each drive. You can add it, update the passwords of a drive that's already there, or skip it.

**Attention: the file and its password together open every drive in it.** Keep them apart.

- **Nothing changes unless you choose it.** Every drive starts on Skip.
- **Nothing is left half-done, and nothing is removed.** Each drive's step either completes or changes nothing, and an import never removes a drive.
- **Each device decides for itself.** Imported drives get new IDs, and the device asks again before sending a password over plain http.

### Drive modes

SFTP drives have three modes, under Advanced in a drive's details. You can switch at any time.

- **Safe** is the default. It works as described above. No save overwrites another computer's, both versions are kept on a conflict, and deleted files are kept in a trash. For this, it keeps a `.cloudmount` folder on the server.
- **Unsafe** leaves nothing on the server but your files. Saves still check that they replace the version you started from, keep both versions on a conflict, and replace the file in a single step. **Attention:** deleted files and replaced versions are gone for good, and if two computers save the same file at the same moment, one save can be lost.
- **Read-only** writes nothing, so no changes can be made.

When you switch to Unsafe or Read-only, the app offers to remove the `.cloudmount` folder, and first tells you what it holds. On an encrypted drive, the `vault` folder inside it stays, because the drive can't be opened without it. Another computer still in Safe mode creates the folder again.

WebDAV drives have only Safe and Read-only, because WebDAV servers can't replace a file in a single step.

### Language

The apps follow your device's language, English or Spanish. To choose one yourself, use Language in Settings on the Mac, or in About on the iPhone. The change takes effect when the app restarts.

### Uninstalling

Deleting an app gives it no chance to clean up after itself, so uninstall from inside the app first. Choose Uninstall… in About, on the Mac or the iPhone. The window lists what will be removed, then shows each step and the result of its check.

1. **On the Mac, it waits for uploads to finish.** It continues by itself when nothing is left to send. You can cancel until then.
2. **It removes each drive** the same way the drive's own Remove button does. On the Mac, files that hadn't uploaded are kept, and the last page shows where.
3. **It deletes what the app keeps on the device.** That means the drive list, each drive's database, cached downloads, the log and the settings. Then it deletes every saved password.
4. **It checks that nothing is left** in Finder or Files, and that no drives, passwords or files remain. A step passes only when its check finds nothing. If a step fails, the window says what's left and why, and Try Again continues from that step.
5. **Then delete the app.** On the Mac, choose Quit, which also turns off launch at login, then move CloudAccess to the Bin. On the iPhone, touch and hold its icon, then choose Remove App.

**Attention: without its password, an encrypted drive can't be read.** Export your drives, or save each recovery kit, before you uninstall.

- **Your servers aren't changed.** The files, the `.cloudmount` folder and each encrypted drive's marker stay, so a new install finds everything as it was.
- **Save Report…** keeps a record of each step, because the log is deleted with everything else. It names drives, but never servers or passwords.
- **macOS keeps each app's own folder** in `~/Library/Containers`. It holds nothing about your drives, and an app can't delete its own.

### Something not working?

On the Mac, choose Export… in the Diagnostics row in Settings. On the iPhone, About has the app's log. Show Log displays it, and Share Log sends it to your Mac with AirDrop. The log records what happened to each drive, and never holds file names or passwords.

## Good to know

- **WebDAV and SFTP only.**
- **Changes made elsewhere aren't instant.** The Mac checks the storage every minute for folders you've used recently, and every 30 minutes for the rest.
- **The app has to be running** for changes made elsewhere to reach Finder. To start it when you log in, turn on Launch at login in Settings.
- **Some Mac-only data stays on the Mac.** Finder tags, symbolic links and some hidden information macOS attaches to files aren't copied to the storage.
- **File dates.** On SFTP, and on WebDAV storage that supports it, such as the Storage Box, a file keeps its own dates. Files put on the storage by other programs show when they arrived there.
- **Replaced versions are kept for a week,** and on WebDAV only up to 2 GB.
- **Git repositories and databases,** such as SQLite files, are only safe when used from one computer at a time.
- **The iPhone only reads.** CloudWanderer and the Files app never change anything on your storage. A download stops if you leave the app.
- **Encrypted drives don't appear in the iPhone's Files app,** only in CloudWanderer, because unlocking one needs more memory than iOS allows there.
- **The Files app** picks up changes while you use it, and whenever you open CloudWanderer. Nothing checks in the background, because this kind of storage can't wake an iPhone.
- **iPhone passwords stay on that iPhone** and aren't included in its backups, unless you export them in a drives file. A new or restored iPhone asks for them again.

### Trade-offs, chosen on purpose

- **The folder layout is visible to the storage.** On encrypted drives, names and contents are hidden, but the storage can still see how many folders there are and how they nest.
- **One password per encrypted drive,** shared by hand. There's no per-person access, and the password can't be changed in place. Moving to a new password means making a new drive.
- **Each save takes about ten small requests.** That's the cost of never overwriting someone else's save on storage that can't do it in one step.
- **After a crash in the middle of a save,** that file can stay blocked for up to 10 minutes.
- **Other programs aren't protected.** Another program writing to the same storage can overwrite a save. Use other programs only for reading and recovery.
- **A computer frozen for over 10 minutes at exactly the wrong moment could overwrite another's save.** Neither WebDAV nor SFTP can rule this out.

## Privacy

- **No tracking or analytics.** The apps connect only to your own storage.
- **Passwords stay in your device's keychain.** They're never put in a QR code, a log or a settings file. They leave it only in a drives file you make yourself, sealed with its own password.
- **Logs leave your device only when you share them.**

## Your files without this app

Everything CloudAccess stores can be read on any computer with [rclone](https://rclone.org), a widely used command-line tool. Use it if the app stops working, your Mac is gone, or you're moving away. Use rclone to get files out, not alongside CloudAccess, because it doesn't take part in the locks that stop two computers overwriting each other.

**Plain drives** are ordinary files on the storage, readable with any WebDAV or SFTP program.

- Ignore the `.cloudmount` folder. It holds uploads in progress and deleted files. A drive in Unsafe or Read-only mode may not have one.
- An Unsafe upload in progress is a hidden file named `.cm-…part` in the drive's top folder.
- Mac documents that are really folders, such as some `.numbers` files, are stored as a single file ending in `.pkgf`. Only a Mac with CloudAccess turns it back into the document.

**Encrypted drives** need the encryption password, which only you have, and the salt, which is in the recovery kit the app offers you. Save that kit. Without the password, the files can't be recovered.

<details>
<summary>Step by step: reading an encrypted drive with rclone</summary>

1. Install rclone from [rclone.org/downloads](https://rclone.org/downloads/).
2. Obscure both values, once each:

   ```sh
   rclone obscure 'your encryption password'
   rclone obscure 'your salt'
   ```

   If you have no recovery kit, the salt is in the `salt` field of the highest-numbered file in `.cloudmount/vault/` on the storage. It isn't secret.
3. Run `rclone config file` to find rclone's settings file, and add your storage to it. For WebDAV:

   ```ini
   [my-server]
   type = webdav
   url = https://example.com/
   vendor = other
   user = your-username
   pass = <output of: rclone obscure 'your server password'>
   ```

   For SFTP:

   ```ini
   [my-server]
   type = sftp
   host = example.com
   port = 22
   user = your-username
   pass = <output of: rclone obscure 'your server password'>
   ```

4. Below it, add the encrypted drive. In `remote`, put your storage's name, a colon, and the drive's folder:

   ```ini
   [cloudaccess-recovery]
   type = crypt
   remote = my-server:the-drive-folder
   filename_encryption = standard
   directory_name_encryption = true
   filename_encoding = base32
   password = <obscured encryption password>
   password2 = <obscured salt>
   ```

5. Copy your files out:

   ```sh
   rclone lsf cloudaccess-recovery:
   rclone copy cloudaccess-recovery: ~/Recovered --progress
   ```

A kit made before the app was renamed calls its section `[cloudmount-recovery]`, so use that name in the commands. rclone prints a notice about `.cloudmount`, because that folder's names aren't encrypted. The notice is harmless. If `lsf` shows nothing, the password or the salt is wrong, because rclone shows an empty folder instead of an error.

</details>

## For developers

### How it works

CloudAccess is a menu bar app with a File Provider extension, the same system iCloud Drive uses. macOS mounts each drive under `~/Library/CloudStorage` and asks the extension for listings and file contents as they're needed. Transfers go through a Go engine built on rclone, so encrypted drives use rclone's crypt format unchanged.

```
Finder → File Provider extension → MountKit → SyncCore → Go engine (rclone) → your server
Menu bar app: settings, status, and checking the server for changes
```

Neither WebDAV nor SFTP can replace a file on condition that nobody else has changed it. So every save:

1. uploads to a staging area on the server;
2. takes a short claim on the file by creating a folder, which both protocols do atomically;
3. checks that the file is still the version the edit started from;
4. copies the old version to the trash and moves the new one into place;
5. releases the claim.

If another device saved first, the new file is kept as a conflict copy instead.

That's Safe mode. In Unsafe mode, which is SFTP only, a save uploads to a hidden file in the drive's top folder, checks the version, and replaces the file with a single rename, which SFTP does in one step. There's no claim and no trash, and nothing is written to `.cloudmount`.

CloudWanderer uses the same engine directly to browse and download. Its read-only Files extension runs the engine in a lean mode, because iOS stops these extensions at about 20 MB of memory.

### Building

You need Xcode 27 and Go 1.26 or later. rclone is optional. When it's installed, the tests that check plain rclone can read a drive use it.

```sh
bash Engine/build.sh all     # builds the engine for macOS, iOS and the simulator
open CloudAccess/CloudAccess.xcodeproj
open CloudWanderer/CloudWanderer.xcodeproj
```

Run the tests:

```sh
go -C Engine test ./...
CLOUDACCESS_TEST_LANGUAGE=en swift test --package-path Packages/CloudCore
```

`CLOUDACCESS_TEST_LANGUAGE=en` runs the Swift tests in English, whatever the Mac's language. They link the built engine, so build it again after changing anything in `Engine/`.

**Debug builds connect only to a server folder named `cloudmount-test`,** so a test build can't touch real files.

**Signing uses the developer's own identifiers.** To run a build on your devices, sign with your own team, and replace `com.infinitecontext` and the App Group names with your own. They appear in the projects, the entitlements and a few source files.

### Layout

| Folder | What's there |
|---|---|
| `Engine/` | Go engine: rclone, the save protocol, and the C interface |
| `Packages/CloudCore/` | Swift package shared by both apps: drives and settings, the engine wrapper, sync state, every decision about what macOS is told, and the shared look |
| `CloudAccess/` | The Mac app and its File Provider extension |
| `CloudWanderer/` | The iPhone app and its read-only Files extension |

## Licence

Apache 2 licensed software. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Developed by InfiniteContext.com.
