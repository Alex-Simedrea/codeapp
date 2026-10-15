import Foundation

/// LSP is a byte stream: SSH reads can split headers, JSON and even UTF-8 scalars.
struct LanguageServerFrameDecoder {
    enum FrameError: Error { case invalidHeader, messageTooLarge, invalidUTF8 }
    private var buffer = Data()
    private let separator = Data("\r\n\r\n".utf8)
    static let maximumMessageSize = 32 * 1024 * 1024

    static func encode(_ message: String) -> Data {
        Data("Content-Length: \(message.utf8.count)\r\n\r\n\(message)".utf8)
    }

    mutating func receive(_ data: Data) throws -> [String] {
        buffer.append(data)
        var messages: [String] = []
        while true {
            guard let boundary = buffer.range(of: separator) else {
                if buffer.count > 64 * 1024 { throw FrameError.invalidHeader }
                return messages
            }
            guard boundary.lowerBound <= 64 * 1024,
                let header = String(data: buffer[..<boundary.lowerBound], encoding: .ascii)
            else { throw FrameError.invalidHeader }
            let lengths = header.components(separatedBy: "\r\n").compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else {
                    return nil
                }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
            guard lengths.count == 1, let length = Int(lengths[0]), length >= 0 else {
                throw FrameError.invalidHeader
            }
            guard length <= Self.maximumMessageSize else { throw FrameError.messageTooLarge }
            let end = boundary.upperBound + length
            guard buffer.count >= end else { return messages }
            guard let message = String(data: buffer[boundary.upperBound..<end], encoding: .utf8)
            else { throw FrameError.invalidUTF8 }
            messages.append(message)
            buffer = Data(buffer.dropFirst(end))
        }
    }
}

enum RemoteClangdCommand {
    static let readyMarker = "CODEAPP_CLANGD_READY\n"

    static func make(workspacePath: String) -> String {
        let quotedPath = "'" + workspacePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // A non-PTY exec channel keeps stdout byte-for-byte intact. No helper is installed remotely.
        return """
            cd \(quotedPath) || exit 1
            command -v clangd >/dev/null 2>&1 && clangd --version >/dev/null 2>&1 || {
                printf '%s\\n' 'Remote C/C++ language service requires clangd on the SSH PATH (clang alone is insufficient).' >&2
                exit 127
            }
            printf '\(readyMarker.replacingOccurrences(of: "\n", with: "\\n"))'
            exec clangd --background-index --log=error
            """
    }
}

// URI JSON produced by Monaco for diagnostics. Paths are already decoded.
struct MonacoResource: Decodable {
    var path: String
    var scheme: String?
    var authority: String?

    var url: URL? {
        if scheme == "file" { return URL(fileURLWithPath: path) }
        if let scheme {
            // Monaco's URI JSON stores a decoded path separately from its authority.
            var components = URLComponents()
            components.scheme = scheme
            if let authority, !authority.isEmpty,
                let remote = URLComponents(string: "\(scheme)://\(authority)")
            {
                components.host = remote.host
                components.port = remote.port
                components.user = remote.user
            }
            components.path = path
            return components.url
        }
        // Compatibility with older Monaco bundles that put the full URI in path.
        return URL(string: String(path.dropFirst()).removingPercentEncoding ?? path)
    }
}
