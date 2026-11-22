import AppKit

enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/vloothuis/nine-lives")!

    /// "2026.11.22" style version from Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The commit the app was built from.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    static func show() {
        let credits = NSMutableAttributedString(
            string: "Simple backups to USB disks and servers, built on BorgBackup.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(
            string: "github.com/vloothuis/nine-lives",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: repositoryURL]))
        credits.addAttribute(
            .paragraphStyle, value: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
            range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Nine Lives",
            .applicationVersion: version,
            .version: "build \(build)",
            .credits: credits,
        ])
    }
}
