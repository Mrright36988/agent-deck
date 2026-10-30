import Foundation

/// How to bring the Cursor window that holds a session to the front.
public enum JumpTarget: Equatable, Sendable {
    /// `cursor <folder>` focuses the window that has exactly this folder open.
    case folder(String)
    /// `cursor <file>` focuses the window of a multi-root workspace: a saved `.code-workspace`, or the
    /// `Workspaces/<id>/workspace.json` Cursor keeps for an untitled one (verified 2026-10-30).
    case workspaceFile(String)
    /// A multi-root window whose workspace file was not found, so no deep link may be sent.
    case unknownWorkspace([String])
    /// No open Cursor window covers this directory.
    case none
}

public struct WorkspaceFile: Sendable, Equatable {
    public let path: String
    public let folders: [String]

    public init(path: String, folders: [String]) {
        self.path = path
        self.folders = folders
    }

    public var isSaved: Bool { path.hasSuffix(".code-workspace") }

    /// Reads a `.code-workspace` or untitled `workspace.json`; relative folder paths resolve against the file.
    public static func parse(_ data: Data, path: String) -> WorkspaceFile? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let entries = object["folders"] as? [[String: Any]] else { return nil }
        let base = (path as NSString).deletingLastPathComponent
        let folders = entries.compactMap { $0["path"] as? String }.map { folder in
            ((folder.hasPrefix("/") ? folder : (base as NSString).appendingPathComponent(folder)) as NSString).standardizingPath
        }
        return WorkspaceFile(path: path, folders: folders)
    }
}

public enum WorkspaceResolver {
    /// The window whose folder most specifically contains `cwd`.
    public static func window(containing cwd: String, in windows: [IDEWindow]) -> IDEWindow? {
        let path = (cwd as NSString).standardizingPath
        let candidates = windows.compactMap { window -> (IDEWindow, Int)? in
            let depth = window.workspaceFolders
                .map { ($0 as NSString).standardizingPath }
                .filter { path == $0 || path.hasPrefix($0 + "/") }
                .map(\.count).max()
            return depth.map { (window, $0) }
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    /// How `window` can be raised. `workspaces` is only consulted for multi-root windows, because reading
    /// workspace files can stall (a file on the Desktop waits on a privacy prompt).
    public static func target(for window: IDEWindow?, workspaces: () -> [WorkspaceFile]) -> JumpTarget {
        guard let window else { return .none }
        let folders = window.workspaceFolders.map { ($0 as NSString).standardizingPath }
        if folders.count == 1 { return .folder(folders[0]) }
        // Cursor deletes an untitled workspace file when its window closes, so one that exists belongs to an
        // open window; a saved file outlives its window, and raising a stale one opens a second window.
        let matches = workspaces().filter { Set($0.folders) == Set(folders) }
        if let file = matches.first(where: { !$0.isSaved }) ?? matches.first {
            return .workspaceFile(file.path)
        }
        return .unknownWorkspace(folders)
    }

    public static func target(for cwd: String, windows: [IDEWindow], workspaces: () -> [WorkspaceFile]) -> JumpTarget {
        target(for: window(containing: cwd, in: windows), workspaces: workspaces)
    }
}
