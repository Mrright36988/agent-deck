import Foundation
import Testing
@testable import DeckCore

private let windows = [
    IDEWindow(pid: 1, workspaceFolders: ["/w/workspace"], ideName: "Cursor"),
    IDEWindow(pid: 2, workspaceFolders: ["/w/devkits", "/w/agent-cli", "/w/developer-portal"], ideName: "Cursor"),
    IDEWindow(pid: 3, workspaceFolders: ["/w/meeting-copilot", "/w/meeting-copilot-native"], ideName: "Cursor"),
    IDEWindow(pid: 4, workspaceFolders: ["/w/workspace/agent-deck/spike/probe-ws"], ideName: "Cursor"),
]
private let workspaces = [
    WorkspaceFile(path: "/w/Desktop/devkits.code-workspace", folders: ["/w/agent-cli", "/w/devkits", "/w/developer-portal"]),
    WorkspaceFile(path: "/w/Library/Cursor/Workspaces/178/workspace.json", folders: ["/w/meeting-copilot", "/w/meeting-copilot-native"]),
]

@Test func singleFolderWindowIsRaisedByFolder() {
    #expect(WorkspaceResolver.target(for: "/w/workspace", windows: windows, workspaces: { workspaces }) == .folder("/w/workspace"))
}

@Test func deepestWindowWinsForNestedFolders() {
    #expect(WorkspaceResolver.target(for: "/w/workspace/agent-deck/spike/probe-ws", windows: windows, workspaces: { workspaces })
            == .folder("/w/workspace/agent-deck/spike/probe-ws"))
}

@Test func savedMultiRootWorkspaceIsRaisedByItsFile() {
    #expect(WorkspaceResolver.target(for: "/w/agent-cli/cmd", windows: windows, workspaces: { workspaces })
            == .workspaceFile("/w/Desktop/devkits.code-workspace"))
}

@Test func singleFolderWindowsNeverReadWorkspaceFiles() {
    // Reading a workspace file can block on a privacy prompt (Desktop); single-folder windows must not need it.
    var read = false
    _ = WorkspaceResolver.target(for: "/w/workspace", windows: windows, workspaces: { read = true; return workspaces })
    #expect(!read)
}

@Test func untitledMultiRootWorkspaceIsRaisedByItsFile() {
    // `cursor <Workspaces/<id>/workspace.json>` focuses the window that has it open (verified 2026-10-30).
    #expect(WorkspaceResolver.target(for: "/w/meeting-copilot", windows: windows, workspaces: { workspaces })
            == .workspaceFile("/w/Library/Cursor/Workspaces/178/workspace.json"))
}

@Test func untitledFileWinsOverSavedFileWithSameFolders() {
    let stale = WorkspaceFile(path: "/w/old/meeting-copilot.code-workspace", folders: ["/w/meeting-copilot-native", "/w/meeting-copilot"])
    #expect(WorkspaceResolver.target(for: "/w/meeting-copilot", windows: windows, workspaces: { [stale] + workspaces })
            == .workspaceFile("/w/Library/Cursor/Workspaces/178/workspace.json"))
}

@Test func multiRootWindowWithoutWorkspaceFileCannotBeAddressed() {
    #expect(WorkspaceResolver.target(for: "/w/meeting-copilot", windows: windows, workspaces: { [] })
            == .unknownWorkspace(["/w/meeting-copilot", "/w/meeting-copilot-native"]))
    #expect(WorkspaceResolver.target(for: "/w/elsewhere", windows: windows, workspaces: { workspaces }) == .none)
}

@Test func workspaceFileResolvesRelativeFoldersAndComments() throws {
    let json = """
    {
      // Cursor writes JSON with comments
      "folders": [{"path": "devkits"}, {"path": "/abs/portal"}],
    }
    """
    let file = try #require(WorkspaceFile.parse(Data(json.utf8), path: "/w/devkits.code-workspace"))
    #expect(file.folders == ["/w/devkits", "/abs/portal"])
    #expect(file.isSaved)
}
