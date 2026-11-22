import SwiftUI
import NineLivesCore

/// Adds a backup server that is reached over SSH.
struct AddServerFlow: View {
    @Environment(BackupCoordinator.self) private var c
    let onDone: () -> Void
    let onBack: () -> Void

    enum Step { case form, installKey, recovery, enterPassphrase, working }

    @State private var step = Step.form
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var port = "22"
    @State private var path = RemoteServer.defaultPath
    @State private var showAdvanced = false
    @State private var publicKey = ""
    @State private var passphrase = PassphraseGenerator.generate()
    @State private var typed = ""
    @State private var confirmedSaved = false
    @State private var error: ShownError?

    private var server: RemoteServer {
        RemoteServer(
            host: host.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            path: path.trimmingCharacters(in: .whitespaces))
    }

    private var formValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .form: form
            case .installKey: installKey
            case .recovery: recovery
            case .enterPassphrase: enterPassphrase
            case .working:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Talking to the server…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error {
                ErrorBox(error: error)
            }
        }
        .padding(24)
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Back up to a server").font(.title2.weight(.semibold))
            Text("Use a server that you reach over SSH, for example a NAS, a rented server or a backup service. The server needs SFTP, which almost every SSH server has. Your backups are always encrypted before they leave this Mac.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Server", text: $host, prompt: Text("nas.local or backup.example.com"))
                TextField("User name", text: $user)
                TextField("Folder on the server", text: $path)
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    TextField("Port", text: $port)
                }
            }
            .formStyle(.columns)
            Spacer(minLength: 0)
            HStack {
                Button("Use a Disk Instead") { onBack() }
                Spacer()
                Button("Continue") { Task { await connect() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!formValid)
            }
        }
    }

    private func connect() async {
        error = nil
        step = .working
        do { publicKey = try c.sshPublicKey() } catch {
            self.error = ShownError(error)
            step = .form
            return
        }
        switch await c.probeServer(server) {
        case .noRepository:
            passphrase = PassphraseGenerator.generate()
            confirmedSaved = false
            step = .recovery
        case .openable:
            await finish(existing: true, passphrase: "")
        case .needsPassphrase:
            step = .enterPassphrase
        case .rejectedKey:
            step = .installKey
        case .hostKeyChanged:
            error = ShownError("The identity of this server changed since you last connected. If you did not reinstall it, do not continue.")
            step = .form
        case .unreachable(let m):
            error = ShownError("Could not reach the server.", details: m)
            step = .form
        case .sftpMissing:
            error = ShownError("The server does not offer SFTP. Turn on the SFTP subsystem in the server's SSH settings and try again.")
            step = .form
        case .failed(let m, let d):
            error = ShownError(m, details: d)
            step = .form
        }
    }

    private func finish(existing: Bool, passphrase: String) async {
        step = .working
        do {
            try await c.addServer(server, passphrase: passphrase, existing: existing)
            onDone()
        } catch {
            self.error = ShownError(error)
            step = existing ? .enterPassphrase : .recovery
        }
    }

    // MARK: Install key

    private var installKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow this Mac on the server").font(.title2.weight(.semibold))
            Text("The server did not accept this Mac yet. Add this key to the server's list of allowed keys, then try again. For a normal server, run the command below once while logged in on the server.")
                .foregroundStyle(.secondary)
            Text(publicKey).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy Key") { copyToPasteboard(publicKey) }
                Button("Copy Command") { copyToPasteboard("mkdir -p ~/.ssh && echo '\(publicKey)' >> ~/.ssh/authorized_keys") }
            }
            Text("Backup services such as rsync.net or Hetzner Storage Box have a page for SSH keys instead. Paste the key there.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = .form; error = nil }
                Spacer()
                Button("Try Again") { Task { await connect() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Passphrase

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save your recovery passphrase").font(.title2.weight(.semibold))
            Text("Your backups are encrypted on this Mac before they are sent. This passphrase is the only way to read them if this Mac is lost. Nine Lives keeps a copy in your Keychain.")
                .foregroundStyle(.secondary)
            Text(passphrase).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy") { copyToPasteboard(passphrase) }
                Button("Save as File…") { savePassphrase(passphrase, diskName: host) }
            }
            Toggle("I saved the passphrase in a safe place, for example a password manager.", isOn: $confirmedSaved)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = .form }
                Spacer()
                Button("Create Backup Folder") { Task { await finish(existing: false, passphrase: passphrase) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!confirmedSaved)
            }
        }
    }

    private var enterPassphrase: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This folder already has backups").font(.title2.weight(.semibold))
            Text("Enter the recovery passphrase that you saved when you set it up.").foregroundStyle(.secondary)
            SecureField("Recovery passphrase", text: $typed).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = .form; error = nil }
                Spacer()
                Button("Connect") {
                    Task { await finish(existing: true, passphrase: typed.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(typed.isEmpty)
            }
        }
    }
}
