import SwiftUI
import UniformTypeIdentifiers
import ResticKit
import NineLivesCore

struct RestoreView: View {
    @Environment(BackupCoordinator.self) private var c
    @Environment(Navigation.self) private var nav

    @State private var diskID: String?
    @State private var archives: [ArchiveInfo] = []
    @State private var archive: ArchiveInfo?
    @State private var catalog: Catalog?
    @State private var path = ""
    @State private var entries: [CatalogEntry] = []
    @State private var selection = Set<CatalogEntry.ID>()
    @State private var search = ""
    @State private var loading: String?
    @State private var loadedCount = 0
    @State private var error: String?
    @State private var restored: URL?
    @State private var confirmOriginal = false

    private var connectedDisks: [KnownDisk] { c.state.disks.filter { c.isConnected($0) } }
    private var disk: KnownDisk? { connectedDisks.first { $0.id == diskID } ?? connectedDisks.first }
    private var selectedEntries: [CatalogEntry] { entries.filter { selection.contains($0.id) } }
    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if connectedDisks.isEmpty {
                ContentUnavailableView("Connect a backup disk", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Plug in one of your backup disks to browse and restore files."))
            } else if let loading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(loading)
                    if loadedCount > 0 { Text("\(loadedCount.formatted()) items").foregroundStyle(.secondary) }
                    Text("This only takes long the first time.").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog != nil {
                browser
            } else if let error {
                ContentUnavailableView("Cannot read the backup", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Restore")
        .searchable(text: $search, prompt: "Search the backup")
        .onChange(of: search) { _, _ in reload() }
        .task(id: connectedDisks.map(\.id)) {
            if let id = nav.restoreDiskID {
                nav.restoreDiskID = nil
                diskID = id
            }
            await loadDisk()
        }
        .onChange(of: nav.restoreDiskID) { _, id in
            guard let id else { return }
            nav.restoreDiskID = nil
            guard id != diskID else { return }
            diskID = id
            Task { await loadDisk() }
        }
        .confirmationDialog("Put the items back where they were?", isPresented: $confirmOriginal) {
            Button("Replace Current Files", role: .destructive) { restore(.originalLocation) }
        } message: {
            Text("Files with the same name are replaced by the backed-up version. This cannot be undone.")
        }
    }

    // MARK: Browser

    private var browser: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(entries, selection: $selection) {
                TableColumn("Name") { e in
                    HStack(spacing: 6) {
                        Image(nsImage: icon(for: e)).resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.name)
                            if isSearching {
                                Text("/" + (e.path.split(separator: "/").dropLast().joined(separator: "/")))
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
                TableColumn("Date Modified") { e in
                    Text(e.modified?.formatted(date: .abbreviated, time: .shortened) ?? "").foregroundStyle(.secondary)
                }.width(150)
                TableColumn("Size") { e in
                    Text(e.isDirectory ? "" : Fmt.bytes(e.size)).foregroundStyle(.secondary)
                }.width(80)
            }
            .contextMenu(forSelectionType: CatalogEntry.ID.self) { ids in
                if let e = entries.first(where: { ids.contains($0.id) }), isSearching {
                    Button("Show in Folder") { search = ""; navigate(to: e.isDirectory ? e.path : parent(of: e.path)) }
                }
            } primaryAction: { ids in
                if let e = entries.first(where: { ids.contains($0.id) }), e.isDirectory {
                    search = ""
                    navigate(to: e.path)
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if connectedDisks.count > 1 {
                Picker("Disk", selection: Binding(get: { disk?.id ?? "" }, set: { diskID = $0; Task { await loadDisk() } })) {
                    ForEach(connectedDisks) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(width: 150)
            }
            Picker("Backup from", selection: Binding(get: { archive?.id ?? "" }, set: { id in
                if let a = archives.first(where: { $0.id == id }) { Task { await select(a) } }
            })) {
                ForEach(archives) { Text($0.date.formatted(date: .abbreviated, time: .shortened)).tag($0.id) }
            }.frame(width: 260)
            Divider().frame(height: 18)
            breadcrumb
            Spacer()
        }
        .padding(10)
    }

    private var breadcrumb: some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            Button { search = ""; navigate(to: "") } label: { Image(systemName: "externaldrive") }.buttonStyle(.plain)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(part) { search = ""; navigate(to: parts[...i].joined(separator: "/")) }.buttonStyle(.plain)
            }
        }.lineLimit(1)
    }

    private var footer: some View {
        HStack {
            if let restored {
                Label("Restored", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Show in Finder") { revealInFinder(restored) }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            } else {
                Text(selection.isEmpty ? "Select files or folders to restore" : "\(selection.count) selected")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Restore To…") {
                Button("Choose Folder…") { chooseFolder() }
                Button("Original Location…") { confirmOriginal = true }
            }
            .fixedSize()
            .disabled(selection.isEmpty || !c.activity.isIdle)
            Button("Restore to Desktop") {
                restore(.folder(FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty || !c.activity.isIdle)
        }
        .padding(10)
    }

    private func icon(for e: CatalogEntry) -> NSImage {
        if e.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    // MARK: Loading

    private func parent(of p: String) -> String {
        p.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func navigate(to newPath: String) {
        path = newPath
        selection = []
        reload()
    }

    private func reload() {
        guard let catalog else { return }
        restored = nil
        error = nil
        entries = isSearching ? catalog.search(search.trimmingCharacters(in: .whitespaces)) : catalog.children(of: path)
    }

    private func loadDisk() async {
        error = nil
        catalog = nil
        guard let disk else { return }
        diskID = disk.id
        loading = "Reading the list of backups…"
        defer { loading = nil }
        do {
            archives = try await c.archives(for: disk)
            guard let newest = archives.first else {
                error = "This disk has no backups yet."
                return
            }
            await select(newest)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func select(_ a: ArchiveInfo) async {
        guard let disk else { return }
        archive = a
        loading = "Reading the contents of this backup…"
        loadedCount = 0
        defer { loading = nil }
        do {
            let counter = ProgressCounter { n in Task { @MainActor in loadedCount = n } }
            catalog = try await c.catalog(for: a, disk: disk) { counter.report($0) }
            search = ""
            let home = String(NSHomeDirectory().dropFirst())
            navigate(to: catalog?.entry(at: home) != nil ? home : "")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Restoring

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        if panel.runModal() == .OK, let url = panel.url { restore(.folder(url)) }
    }

    private func restore(_ target: RestoreTarget) {
        guard let disk, let archive else { return }
        let items = selectedEntries
        restored = nil
        error = nil
        Task {
            loading = "Restoring \(items.count) item\(items.count == 1 ? "" : "s")…"
            defer { loading = nil }
            do {
                restored = try await c.restore(entries: items, from: archive, disk: disk, target: target)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Throttles progress callbacks from a background thread.
final class ProgressCounter: @unchecked Sendable {
    private var last = 0
    private let sink: (Int) -> Void
    init(_ sink: @escaping (Int) -> Void) { self.sink = sink }
    func report(_ n: Int) {
        if n - last >= 5000 { last = n; sink(n) }
    }
}
