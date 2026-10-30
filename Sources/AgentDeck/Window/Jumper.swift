import AppKit
import DeckCore

/// Brings the Cursor window of a session to the front.
///
/// Deep links land in whichever Cursor window was active last, and a session opened in the wrong window
/// gets a second panel, and a second process once someone types there (M0). `cursor <path>` returning
/// does not mean its window is already frontmost: on 2026-10-29 a deep link sent right after it opened
/// the session in another window. So without a way to confirm the frontmost window (Accessibility),
/// the deck raises the window only and names the tab to pick.
@MainActor
enum Jumper {
    enum Outcome {
        /// The window is in front; the message names the tab to pick.
        case windowOnly(String)
        /// The window could not be brought to the front (at most Cursor itself was activated).
        case unavailable(String)
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let cursorCLI = ["/usr/local/bin/cursor", "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func jump(to session: Session) async -> Outcome {
        let windows = IDELocks.load(directory: home.appendingPathComponent(".claude/ide")).filter { $0.ideName == "Cursor" }
        guard let window = WorkspaceResolver.window(containing: session.cwd, in: windows) else {
            return .unavailable("没有找到打开「\(session.project)」的 Cursor 窗口")
        }
        Log.write("jump \(session.tool.rawValue) \(session.id.prefix(8))")
        return await raise(window, name: session.project, tab: session.displayTitle)
    }

    /// Brings `window` to the front; `tab` names the session tab to pick once it is there.
    static func raise(_ window: IDEWindow, name: String, tab: String? = nil) async -> Outcome {
        var workspaces: [WorkspaceFile] = []
        if window.workspaceFolders.count > 1 {
            let folders = window.workspaceFolders
            workspaces = await Task.detached(priority: .userInitiated) { workspaceFiles(matching: folders) }.value
        }
        let path: String
        switch WorkspaceResolver.target(for: window, workspaces: { workspaces }) {
        case .folder(let folder):
            path = folder
        case .workspaceFile(let file):
            path = file
        case .unknownWorkspace:
            activateCursor()
            return .unavailable("没找到「\(name)」所在多根 workspace 的配置文件，只能切到 Cursor")
        case .none:
            return .unavailable("没有找到打开「\(name)」的 Cursor 窗口")
        }
        guard await runCursor(path) else {
            return .unavailable("cursor 命令执行失败")
        }
        Log.write("raised \(path)")
        return .windowOnly(tab.map { "已切到「\(name)」窗口，会话是右侧的「\($0)」" } ?? "已切到「\(name)」窗口")
    }

    private static func runCursor(_ path: String) async -> Bool {
        guard let cli = cursorCLI else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = [path]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private static func activateCursor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Cursor.app"), configuration: .init())
    }

    /// The workspace file Cursor has for `folders`, if any. Untitled workspaces are tried first (see
    /// `WorkspaceResolver.target`). Runs off the main actor: a file in a protected folder (Desktop,
    /// Documents, …) blocks on a privacy prompt, so those are read last and only if needed.
    nonisolated private static func workspaceFiles(matching folders: [String]) -> [WorkspaceFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { "\(home)/\($0)/" } + ["/Volumes/"]
        let storage = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        let entries = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        let paths = Set(entries.compactMap { entry -> String? in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("workspace.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uri = object["workspace"] as? String, let url = URL(string: uri), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url.path
        })
        func rank(_ path: String) -> Int {
            if !path.hasSuffix(".code-workspace") { return 0 }
            return protected.contains(where: path.hasPrefix) ? 2 : 1
        }
        let ordered = paths.sorted { rank($0) < rank($1) }
        let wanted = Set(folders.map { ($0 as NSString).standardizingPath })
        for path in ordered {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let file = WorkspaceFile.parse(data, path: path) else { continue }
            if Set(file.folders) == wanted { return [file] }
        }
        return []
    }
}
