import Foundation

// Built-in rules for developer tools and macOS. Everything here is rebuilt or downloaded again by
// the tool that made it. Names that are common words (build, dist, target, vendor, Library) are
// left out on purpose, because they can hold real work.
//
// Folders that hold secrets or settings (.ssh, .aws, .docker, .gem, .bundle, .cargo as a whole,
// .m2/settings.xml, .kube/config) are never listed. Only their regenerable sub-folders are.

private typealias Item = (title: String, kind: ExcludeRule.Kind, value: String)

private func group(_ category: String, _ detail: String, ask: Bool = false, _ items: [Item]) -> [ExcludeRule] {
    items.map {
        ExcludeRule(id: "\($0.kind.rawValue):\($0.value)", title: $0.title, detail: detail,
                    kind: $0.kind, value: $0.value, category: category, ask: ask)
    }
}

extension DefaultRules {
    static let developer: [ExcludeRule] =
        javascript + python + rust + golang + jvm + apple + native + dotnet + ruby + php
        + functional + mobile + games + infrastructure + editors + toolchains

    static let macOS: [ExcludeRule] = system + browsersAndApps + media + vmsAndDevices

    // MARK: Developer tools

    private static let javascript = group("JavaScript and TypeScript", "Created again by npm, your bundler or the dev server.", [
        ("Next.js build output", .anywhere, ".next"),
        ("Nuxt build output", .anywhere, ".nuxt"),
        ("Nuxt server build", .anywhere, ".output"),
        ("SvelteKit build output", .anywhere, ".svelte-kit"),
        ("Parcel cache", .anywhere, ".parcel-cache"),
        ("Turborepo cache", .anywhere, ".turbo"),
        ("Nx cache", .anywhere, ".nx/cache"),
        ("Angular cache", .anywhere, ".angular/cache"),
        ("Vite cache", .anywhere, ".vite"),
        ("Astro cache", .anywhere, ".astro"),
        ("Docusaurus cache", .anywhere, ".docusaurus"),
        ("Expo cache", .anywhere, ".expo"),
        ("Built Storybook", .anywhere, "storybook-static"),
        ("Bower packages", .anywhere, "bower_components"),
        ("jspm packages", .anywhere, "jspm_packages"),
        ("ESLint cache", .anywhere, ".eslintcache"),
        ("Stylelint cache", .anywhere, ".stylelintcache"),
        ("TypeScript build info", .anywhere, "*.tsbuildinfo"),
        ("pnpm store in a project", .anywhere, ".pnpm-store"),
        ("pnpm store", .home, "Library/pnpm/store"),
        ("Bun cache", .home, ".bun/install/cache"),
        ("Yarn cache", .home, ".yarn/berry/cache"),
        ("Node headers for native add-ons", .home, ".node-gyp"),
        ("Electron downloads", .home, ".electron"),
    ])

    private static let python = group("Python", "Created again by Python, pip or uv.", [
        ("Python bytecode caches", .anywhere, "__pycache__"),
        ("Compiled Python files", .anywhere, "*.pyc"),
        ("Optimised Python files", .anywhere, "*.pyo"),
        ("Virtual environments named .venv", .anywhere, ".venv"),
        ("Virtual environments with any name", .marker, "pyvenv.cfg"),
        ("PDM packages", .anywhere, "__pypackages__"),
        ("Pixi environments", .anywhere, ".pixi"),
        ("tox environments", .anywhere, ".tox"),
        ("nox environments", .anywhere, ".nox"),
        ("Python build helpers", .anywhere, ".eggs"),
        ("Python package metadata", .anywhere, "*.egg-info"),
        ("mypy cache", .anywhere, ".mypy_cache"),
        ("pytest cache", .anywhere, ".pytest_cache"),
        ("Ruff cache", .anywhere, ".ruff_cache"),
        ("pytype cache", .anywhere, ".pytype"),
        ("Hypothesis database", .anywhere, ".hypothesis"),
        ("Jupyter autosave copies", .anywhere, ".ipynb_checkpoints"),
        ("Coverage report", .anywhere, "htmlcov"),
        ("PDM build folder", .anywhere, ".pdm-build"),
        ("virtualenvwrapper environments", .home, ".virtualenvs"),
        ("pipenv environments", .home, ".local/share/virtualenvs"),
        ("pipx tools", .home, ".local/pipx"),
        ("pyenv downloads", .home, ".pyenv/cache"),
        ("Conda packages", .home, "miniconda3/pkgs"),
        ("Miniforge packages", .home, "miniforge3/pkgs"),
        ("Anaconda packages", .home, "anaconda3/pkgs"),
        ("Conda packages in .conda", .home, ".conda/pkgs"),
    ])

    private static let rust = group("Rust", "Created again by Cargo. Rust target folders are skipped too, because Cargo marks them as caches.", [
        ("Cargo git dependencies", .home, ".cargo/git"),
        ("rustup downloads", .home, ".rustup/downloads"),
        ("rustup temporary files", .home, ".rustup/tmp"),
    ])

    private static let golang = group("Go", "Downloaded again by the go command.", [
        ("Go module cache", .home, "go/pkg/mod"),
        ("Go checksum cache", .home, "go/pkg/sumdb"),
    ])

    private static let jvm = group("Java, Kotlin and Scala", "Downloaded or compiled again by your build tool.", [
        ("Gradle wrapper downloads", .home, ".gradle/wrapper/dists"),
        ("Gradle daemon data", .home, ".gradle/daemon"),
        ("Kotlin session data", .anywhere, ".kotlin"),
        ("Kotlin/Native toolchain", .home, ".konan"),
        ("Compiled Java classes", .anywhere, "*.class"),
        ("Ivy cache", .home, ".ivy2/cache"),
        ("sbt launcher files", .home, ".sbt/boot"),
        ("Bloop data", .anywhere, ".bloop"),
        ("Metals data", .anywhere, ".metals"),
        ("Build Server Protocol data", .anywhere, ".bsp"),
        ("Scala build data", .anywhere, ".scala-build"),
        ("Clojure classpath cache", .anywhere, ".cpcache"),
        ("ClojureScript build cache", .anywhere, ".shadow-cljs"),
    ])

    private static let apple = group("Swift and Xcode", "Created again by Xcode or Swift Package Manager.", [
        ("Swift Package Manager build folder", .anywhere, ".build"),
        ("Xcode build data anywhere", .anywhere, "DerivedData"),
        ("iOS device debug symbols", .home, "Library/Developer/Xcode/iOS DeviceSupport"),
        ("watchOS device debug symbols", .home, "Library/Developer/Xcode/watchOS DeviceSupport"),
        ("tvOS device debug symbols", .home, "Library/Developer/Xcode/tvOS DeviceSupport"),
        ("Xcode documentation cache", .home, "Library/Developer/Xcode/DocumentationCache"),
        ("Xcode playground simulators", .home, "Library/Developer/XCPGDevices"),
        ("Xcode test devices", .home, "Library/Developer/XCTestDevices"),
        ("CocoaPods specs", .home, ".cocoapods/repos"),
        ("Carthage checkouts", .anywhere, "Carthage/Checkouts"),
        ("Carthage builds", .anywhere, "Carthage/Build"),
    ])

    private static let native = group("C, C++ and embedded", "Created again by your compiler or build system.", [
        ("Compiled object files", .anywhere, "*.o"),
        ("Precompiled headers", .anywhere, "*.gch"),
        ("CMake build files", .anywhere, "CMakeFiles"),
        ("CMake cache", .anywhere, "CMakeCache.txt"),
        ("CLion debug build", .anywhere, "cmake-build-debug"),
        ("CLion release build", .anywhere, "cmake-build-release"),
        ("ccls index", .anywhere, ".ccls-cache"),
        ("vcpkg packages", .anywhere, "vcpkg_installed"),
        ("Conan 2 packages", .home, ".conan2/p"),
        ("Conan 1 packages", .home, ".conan/data"),
        ("Bazel output", .anywhere, "bazel-out"),
        ("Bazel binaries", .anywhere, "bazel-bin"),
        ("Bazel test logs", .anywhere, "bazel-testlogs"),
        ("PlatformIO build folder", .anywhere, ".pio"),
        ("PlatformIO toolchains", .home, ".platformio/packages"),
        ("Zig cache", .anywhere, ".zig-cache"),
        ("Zig cache (old name)", .anywhere, "zig-cache"),
        ("Zig output", .anywhere, "zig-out"),
        ("Nim generated code", .anywhere, "nimcache"),
    ])

    private static let dotnet = group(".NET", "Restored or built again by dotnet.", [
        ("NuGet packages", .home, ".nuget/packages"),
        ("NuGet plugin cache", .home, ".nuget/plugins-cache"),
        ("NuGet web cache", .home, ".local/share/NuGet"),
        ("Folders with restored .NET packages (obj)", .marker, "project.assets.json"),
        ("Visual Studio cache", .anywhere, ".vs"),
        ("Test results", .anywhere, "TestResults"),
    ])

    private static let ruby = group("Ruby", "Installed again by Bundler or gem.", [
        ("Gems installed in a project", .anywhere, "vendor/bundle"),
        ("Bundler cache", .home, ".bundle/cache"),
        ("Gems installed for you", .home, ".gem/ruby"),
        ("YARD cache", .anywhere, ".yardoc"),
        ("Sass cache", .anywhere, ".sass-cache"),
        ("Jekyll cache", .anywhere, ".jekyll-cache"),
        ("Built static site", .anywhere, "_site"),
    ])

    private static let php = group("PHP", "Downloaded or rebuilt again by Composer or PHPUnit.", [
        ("Composer cache", .home, ".composer/cache"),
        ("PHPUnit cache", .anywhere, ".phpunit.cache"),
        ("PHPUnit result cache", .anywhere, ".phpunit.result.cache"),
        ("PHP CS Fixer cache", .anywhere, ".php-cs-fixer.cache"),
    ])

    private static let functional = group("Elixir, Haskell, OCaml and others", "Downloaded or built again by the language tools.", [
        ("Build output (Mix, rebar3, dune)", .anywhere, "_build"),
        ("Elixir language server data", .anywhere, ".elixir_ls"),
        ("Hex packages", .home, ".hex/packages"),
        ("Mix archives", .home, ".mix/archives"),
        ("Haskell Stack build folder", .anywhere, ".stack-work"),
        ("Cabal build folder", .anywhere, "dist-newstyle"),
        ("Stack snapshots", .home, ".stack/snapshots"),
        ("Stack compilers", .home, ".stack/programs"),
        ("Cabal packages", .home, ".cabal/packages"),
        ("Cabal store", .home, ".cabal/store"),
        ("Local opam switch", .anywhere, "_opam"),
        ("Elm packages", .anywhere, "elm-stuff"),
        ("Julia compiled files", .home, ".julia/compiled"),
        ("Julia packages", .home, ".julia/packages"),
        ("Julia artifacts", .home, ".julia/artifacts"),
        ("Julia registries", .home, ".julia/registries"),
        ("Nim packages", .home, ".nimble/pkgs"),
    ])

    private static let mobile = group("Dart, Flutter and Android", "Downloaded or generated again by the SDK tools.", [
        ("Dart and Flutter tool data", .anywhere, ".dart_tool"),
        ("Flutter plugin list", .anywhere, ".flutter-plugins"),
        ("Flutter plugin dependencies", .anywhere, ".flutter-plugins-dependencies"),
        ("Dart and Flutter packages", .home, ".pub-cache"),
        ("Android tool cache", .home, ".android/cache"),
        ("Android build cache", .home, ".android/build-cache"),
    ])

    private static let games = group("Game engines", "Created again when the project is opened.", [
        ("Godot import cache", .anywhere, ".godot"),
        ("Unreal derived data cache", .anywhere, "DerivedDataCache"),
    ])

    private static let infrastructure = group("Infrastructure tools", "Downloaded or generated again by the tool.", [
        ("Terraform providers and modules", .anywhere, ".terraform"),
        ("Terragrunt cache", .anywhere, ".terragrunt-cache"),
        ("Terraform plugin cache", .home, ".terraform.d/plugin-cache"),
        ("Pulumi plugins", .home, ".pulumi/plugins"),
        ("Serverless build files", .anywhere, ".serverless"),
        ("AWS SAM build output", .anywhere, ".aws-sam"),
        ("AWS CDK output", .anywhere, "cdk.out"),
        ("Vagrant boxes", .home, ".vagrant.d/boxes"),
        ("Minikube data", .home, ".minikube"),
        ("kubectl cache", .home, ".kube/cache"),
        ("direnv cache", .anywhere, ".direnv"),
        ("devenv state", .anywhere, ".devenv"),
    ])

    private static let editors = group("Editors and IDEs", "Downloaded or compiled again by the editor.", [
        ("VS Code compiled script cache", .anywhere, "CachedData"),
        ("VS Code extension downloads", .anywhere, "CachedExtensionVSIXs"),
        ("VS Code extension test downloads", .anywhere, ".vscode-test"),
        ("VS Code logs", .home, "Library/Application Support/Code/logs"),
        ("JetBrains IDEs installed by Toolbox", .home, "Library/Application Support/JetBrains/Toolbox/apps"),
    ])

        private static let toolchains = group("Installed toolchains and SDKs", "Can be installed again, but that takes time. Skipped until you decide. Nine Lives asks after a backup when it finds more than 2 GB.", ask: true, [
        ("Rust toolchains", .home, ".rustup/toolchains"),
        ("Python versions from pyenv", .home, ".pyenv/versions"),
        ("Node versions from nvm", .home, ".nvm/versions"),
        ("Node versions from Volta", .home, ".volta/tools"),
        ("Node versions from fnm", .home, ".local/share/fnm"),
        ("Ruby versions from rbenv", .home, ".rbenv/versions"),
        ("Ruby versions from RVM", .home, ".rvm/rubies"),
        ("Python versions from uv", .home, ".local/share/uv"),
        ("Haskell toolchains", .home, ".ghcup"),
        ("Extra Go versions", .home, "sdk"),
        ("JDKs and tools from SDKMAN", .home, ".sdkman/candidates"),
        ("Android SDK", .home, "Library/Android/sdk"),
    ])

    // MARK: macOS

    private static let system = group("System and apps", "Rebuilt by macOS or the app that made it.", [
        ("Saved window states", .home, "Library/Saved Application State"),
        ("Crash reports", .home, "Library/Application Support/CrashReporter"),
        ("Spotlight index", .anywhere, ".Spotlight-V100"),
        ("File change log", .anywhere, ".fseventsd"),
        ("Document version database", .anywhere, ".DocumentRevisions-V100"),
        ("Temporary items", .anywhere, ".TemporaryItems"),
        ("Trash on other disks", .anywhere, ".Trashes"),
        ("Time Machine backups", .anywhere, "Backups.backupdb"),
    ])

    private static let browsersAndApps = group("Browser and app caches", "Cache folders of Chrome, Edge, Arc, Slack, Discord and other Electron apps. They fill again when you use the app.", [
        ("Cache folders of apps", .anywhere, "Library/Application Support/*/Cache"),
        ("Code caches of apps", .anywhere, "Library/Application Support/*/Code Cache"),
        ("GPU caches of apps", .anywhere, "Library/Application Support/*/GPUCache"),
        ("Dawn caches of apps", .anywhere, "Library/Application Support/*/DawnCache"),
        ("Shader caches of apps", .anywhere, "Library/Application Support/*/GrShaderCache"),
        ("Offline web caches", .anywhere, "Service Worker/CacheStorage"),
        ("Offline script caches", .anywhere, "Service Worker/ScriptCache"),
        ("Google Drive streaming cache", .home, "Library/Application Support/Google/DriveFS"),
        ("Spotify offline cache", .home, "Library/Application Support/Spotify/PersistentCache"),
        ("Adobe media cache files", .home, "Library/Application Support/Adobe/Common/Media Cache Files"),
        ("Adobe media cache", .home, "Library/Application Support/Adobe/Common/Media Cache"),
        ("Steam games", .home, "Library/Application Support/Steam/steamapps"),
    ])

    private static let media = group("Large media and device backups", "Large, and in some cases the only copy. Skipped until you decide. Nine Lives asks after a backup when it finds more than 2 GB.", ask: true, [
        ("iPhone and iPad backups", .home, "Library/Application Support/MobileSync/Backup"),
        ("Xcode archives", .home, "Library/Developer/Xcode/Archives"),
        ("Downloaded Apple Music", .home, "Music/Music/Media.localized/Apple Music"),
        ("Lightroom previews", .anywhere, "*.lrdata"),
        ("Final Cut cache files", .anywhere, "*.fcpcache"),
    ])

    private static let vmsAndDevices = group("Virtual machines and containers", "Very large. Skipped until you decide. Nine Lives asks after a backup when it finds more than 2 GB.", ask: true, [
        ("VirtualBox machines", .home, "VirtualBox VMs"),
        ("Parallels folder", .home, "Parallels"),
        ("Virtual disks (vdi)", .anywhere, "*.vdi"),
        ("Virtual disks (vmdk)", .anywhere, "*.vmdk"),
        ("Virtual disks (qcow2)", .anywhere, "*.qcow2"),
        ("Podman data", .home, ".local/share/containers"),
        ("Colima machines", .home, ".colima"),
        ("Lima machines", .home, ".lima"),
        ("OrbStack data", .home, ".orbstack"),
        ("Docker Desktop group data", .home, "Library/Group Containers/group.com.docker"),
    ])
}
