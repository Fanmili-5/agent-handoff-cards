import AppKit
import SwiftUI

@main
struct AgentHandoffApp: App {
    @StateObject private var store = HandoffStore()

    var body: some Scene {
        Window("Agent Handoff", id: "handoff") {
            HandoffPane(store: store)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 980, height: 660)
    }
}

enum HandoffCommand {
    static func call(_ arguments: [String]) throws -> Data {
        guard let python = Bundle.main.object(forInfoDictionaryKey: "HandoffPython") as? String,
              let script = Bundle.main.url(forResource: "handoff", withExtension: "py"),
              FileManager.default.isExecutableFile(atPath: python) else {
            throw CommandError("找不到构建时使用的 Python。请从源码重新构建工作台。")
        }
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.currentDirectoryURL = script.deletingLastPathComponent()
        task.arguments = ["-B", "-E", "-s", script.path] + arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw CommandError(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    private struct CommandError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
