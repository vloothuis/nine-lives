import SwiftUI
import NineLivesCore

struct AddDiskSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            AddDiskFlow(onDone: { dismiss() })
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 520, height: 560)
    }
}

/// Picks a disk and creates or opens its backup folder.
struct AddDiskFlow: View {
    @Environment(BackupCoordinator.self) private var c
    let onDone: () -> Void

    enum Step { case choose, recovery, enterPassphrase, working, server }

    @State private var step = Step.choose
    @State private var selectedID: String?
    @State private var passphrase = PassphraseGenerator.generate()
    @State private var typed = ""
    @State private var confirmedSaved = false
    @State private var error: ShownError?

    private var candidates: [VolumeInfo] { c.monitor.volumes.filter { v in !c.state.disks.contains { $0.id == v.id } } }
    private var selected: VolumeInfo? { candidates.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .server: AddServerFlow(onDone: onDone, onBack: { step = .choose })
            case .choose: chooseStep
            case .recovery: recoveryStep
            case .enterPassphrase: enterStep
            case .working:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Setting up your disk…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error {
                ErrorBox(error: error)
            }
        }
        .padding(step == .server ? 0 : 24)
        .task { await c.monitor.refresh(announce: false) }
    }

    // MARK: Choose

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a backup disk").font(.title2.weight(.semibold))
            Text("Plug in a USB disk. Backups are saved in their own folder, your other files on the disk stay untouched.")
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                ContentUnavailableView("No disk found", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Connect a USB disk and it will appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(candidates, selection: $selectedID) { v in
                    HStack {
                        Image(systemName: "externaldrive.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(v.name)
                            Text("\(Fmt.bytes(v.totalCapacity)) · \(v.filesystemDisplayName) · \(v.isEncrypted ? "Encrypted" : "Not encrypted")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(v.id)
                }
                .frame(minHeight: 130)
            }
            if let v = selected { advice(for: v) }
            Spacer(minLength: 0)
            HStack {
                Button("Use a Server Instead…") { step = .server }
                Spacer()
                Button("Continue") { Task { await proceed() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || selected?.isSupportedFilesystem == false || selected?.isWritable == false)
            }
        }
    }

    @ViewBuilder private func advice(for v: VolumeInfo) -> some View {
        if !v.isWritable {
            Label("This disk is read-only.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if !v.isSupportedFilesystem {
            Label("This disk is formatted as \(v.filesystemDisplayName). Reformat it as APFS in Disk Utility first. This erases the disk.",
                  systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            if v.isEncrypted {
                Label("The disk is encrypted. Your backups are protected without an extra passphrase.", systemImage: "lock.fill")
                    .foregroundStyle(.green)
            } else {
                Label("The disk is not encrypted. Nine Lives will encrypt the backups with a passphrase that you keep safe. You can also encrypt the whole disk in Finder: right-click the disk and choose Encrypt.",
                      systemImage: "lock.open").foregroundStyle(.secondary)
            }
            if v.availableCapacity < 20_000_000_000 {
                Label("Only \(Fmt.bytes(v.availableCapacity)) is free. A larger disk keeps more history.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func proceed() async {
        guard let v = selected else { return }
        error = nil
        step = .working
        switch await c.probeExisting(on: v) {
        case .openable:
            await finish { try await c.adoptDisk(v, passphrase: nil) }
        case .needsPassphrase:
            step = .enterPassphrase
        case .unreadable(let msg):
            error = ShownError("The backup folder on this disk cannot be read.", details: msg)
            step = .choose
        case .none:
            if v.isEncrypted {
                await finish { try await c.addNewDisk(v, passphrase: nil) }
            } else {
                passphrase = PassphraseGenerator.generate()
                confirmedSaved = false
                step = .recovery
            }
        }
    }

    private func finish(_ work: () async throws -> Void) async {
        step = .working
        do {
            try await work()
            onDone()
        } catch {
            self.error = ShownError(error)
            step = .choose
        }
    }

    // MARK: Recovery passphrase

    private var recoveryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save your recovery passphrase").font(.title2.weight(.semibold))
            Text("Your backups are encrypted. This passphrase is the only way to read them if this Mac is lost or reinstalled. Nine Lives keeps a copy in your Keychain.")
                .foregroundStyle(.secondary)
            Text(passphrase).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy") { copyToPasteboard(passphrase) }
                Button("Save as File…") { savePassphrase(passphrase, diskName: selected?.name ?? "disk") }
            }
            Toggle("I saved the passphrase in a safe place, for example a password manager.", isOn: $confirmedSaved)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = .choose }
                Spacer()
                Button("Create Backup Folder") {
                    guard let v = selected else { return }
                    Task { await finish { try await c.addNewDisk(v, passphrase: passphrase) } }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!confirmedSaved)
            }
        }
    }

    // MARK: Existing repository

    private var enterStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This disk already has backups").font(.title2.weight(.semibold))
            Text("Enter the recovery passphrase that you saved when you set up this disk.").foregroundStyle(.secondary)
            SecureField("Recovery passphrase", text: $typed).textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = .choose; error = nil }
                Spacer()
                Button("Connect") {
                    guard let v = selected else { return }
                    Task {
                        await finish { try await c.adoptDisk(v, passphrase: typed.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        if error != nil { step = .enterPassphrase }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(typed.isEmpty)
            }
        }
    }
}
