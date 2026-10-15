import Foundation

@main
struct LanguageServerProtocolTests {
    static func main() throws {
        let messages = ["{\"text\":\"héllo 🌍\"}", "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":null}"]
        let stream = messages.reduce(into: Data()) { $0.append(LanguageServerFrameDecoder.encode($1)) }
        // Every possible SSH packet boundary, including in the middle of a UTF-8 scalar.
        for boundary in 0...stream.count {
            var decoder = LanguageServerFrameDecoder()
            let first = try decoder.receive(Data(stream.prefix(boundary)))
            let second = try decoder.receive(Data(stream.dropFirst(boundary)))
            precondition(first + second == messages)
        }
        var decoder = LanguageServerFrameDecoder()
        var received: [String] = []
        for byte in stream { received += try decoder.receive(Data([byte])) }
        precondition(received == messages)
        var contentType = LanguageServerFrameDecoder()
        let typedMessages = try contentType.receive(Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 2\r\n\r\n{}".utf8))
        precondition(typedMessages == ["{}"])
        for header in ["Content-Length: -1", "Content-Length: 99999999999999", "Content-Length: 2\r\nContent-Length: 2", "Missing: 2"] {
            var invalid = LanguageServerFrameDecoder()
            do {
                _ = try invalid.receive(Data("\(header)\r\n\r\n{}".utf8))
                fatalError("Accepted invalid header: \(header)")
            } catch {}
        }
        let fixturePath = "/tmp/codeapp space ' ; $(touch SHOULD_NOT_EXIST)"
        let command = RemoteClangdCommand.make(workspacePath: fixturePath)
        precondition(command.contains("cd '/tmp/codeapp space '\\'' ; $(touch SHOULD_NOT_EXIST)'"))
        let localPath = "/tmp/project café #1/main.c"
        let local = MonacoResource(path: localPath, scheme: "file", authority: "")
        precondition(local.url == URL(fileURLWithPath: localPath))
        let remote = MonacoResource(path: localPath, scheme: "sftp", authority: "user@[2001:db8::1]:2222")
        precondition(remote.url?.scheme == "sftp")
        precondition(remote.url?.port == 2222)
        precondition(remote.url?.path == localPath)
        precondition(remote.url?.user == "user")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeapp-lsp-" + UUID().uuidString)
            .appendingPathComponent("project ' with spaces $()")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "PATH=/nonexistent\n" + RemoteClangdCommand.make(workspacePath: directory.path)]
        let errors = Pipe(), output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 127)
        let warning = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(warning.contains("requires clangd"))
        precondition(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        print("PASS: fragmented/coalesced/UTF-8 LSP frames, invalid/oversized frames, diagnostic URLs, shell quoting, missing-clangd guard")
    }
}
