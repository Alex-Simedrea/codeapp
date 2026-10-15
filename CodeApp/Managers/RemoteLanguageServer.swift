import Foundation
import NMSSH

/// An exec channel on the authenticated SFTP connection, including its jump-host tunnel.
/// Every libssh2 call runs on the provider's serial queue alongside SFTP operations.
final class RemoteLanguageServer {
    private let session: NMSSHSession
    private let queue: DispatchQueue
    private let workspace: URL
    private let onEvent: (String, String) -> Void
    private var channel: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var decoder = LanguageServerFrameDecoder()
    private var startup = Data()
    private var stderrTail = Data()
    private var pendingWrites: [Data] = []
    private var writeOffset = 0
    private var startedAt = Date()
    private var ready = false
    private var stopped = false

    init(
        session: NMSSHSession, queue: DispatchQueue, workspace: URL,
        onEvent: @escaping (String, String) -> Void
    ) {
        self.session = session
        self.queue = queue
        self.workspace = workspace
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard !stopped, channel == nil else { return }
            guard session.isConnected, session.isAuthorized, let rawSession = session.session
            else {
                finish(error: "The SSH file connection is no longer available.")
                return
            }
            let blocking = libssh2_session_get_blocking(rawSession)
            libssh2_session_set_blocking(rawSession, 1)
            defer { libssh2_session_set_blocking(rawSession, blocking) }
            guard
                let newChannel = libssh2_channel_open_ex(
                    rawSession, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
            else {
                finish(error: "Unable to open an SSH channel for clangd.")
                return
            }
            channel = newChannel
            let command = RemoteClangdCommand.make(workspacePath: workspace.path)
            guard
                libssh2_channel_process_startup(
                    newChannel, "exec", 4, command, UInt32(command.utf8.count)) == 0
            else {
                finish(error: "The SSH server refused to start clangd.")
                return
            }
            startedAt = Date()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now(), repeating: .milliseconds(15), leeway: .milliseconds(5))
            source.setEventHandler { [weak self] in self?.pump() }
            timer = source
            source.resume()
        }
    }

    func send(_ message: String) {
        queue.async { [self] in
            guard !stopped else { return }
            pendingWrites.append(LanguageServerFrameDecoder.encode(message))
            pump()
        }
    }

    func stop() {
        queue.async { [self] in finish() }
    }

    /// Called by the SFTP provider before it tears down the session, on the same queue.
    func stopOnQueue() { finish() }

    private func emit(_ event: String, _ value: String = "") {
        DispatchQueue.main.async { [onEvent] in onEvent(event, value) }
    }

    private func pump() {
        guard !stopped, let channel, let rawSession = session.session else { return }
        let blocking = libssh2_session_get_blocking(rawSession)
        libssh2_session_set_blocking(rawSession, 0)
        defer { libssh2_session_set_blocking(rawSession, blocking) }

        // Keep a stable buffer and offset after EAGAIN/partial writes. Never interleave messages.
        for _ in 0..<32 {
            guard let data = pendingWrites.first else { break }
            let count = data.withUnsafeBytes { bytes in
                libssh2_channel_write_ex(
                    channel, 0,
                    bytes.baseAddress!.advanced(by: writeOffset).assumingMemoryBound(
                        to: CChar.self),
                    data.count - writeOffset)
            }
            if count == LIBSSH2_ERROR_EAGAIN || count == 0 { break }
            guard count > 0 else {
                finish(error: "Writing to remote clangd failed.")
                return
            }
            writeOffset += count
            if writeOffset == data.count {
                pendingWrites.removeFirst()
                writeOffset = 0
            }
        }

        var bytes = [CChar](repeating: 0, count: 32768)
        for stream: Int32 in [0, 1] {
            for _ in 0..<32 {
                let count = libssh2_channel_read_ex(channel, stream, &bytes, bytes.count)
                if count == LIBSSH2_ERROR_EAGAIN || count == 0 { break }
                guard count > 0 else {
                    finish(error: "Reading from remote clangd failed.")
                    return
                }
                let data = bytes.withUnsafeBytes { Data($0.prefix(count)) }
                if stream == 1 {
                    stderrTail.append(data)
                    stderrTail = Data(stderrTail.suffix(4096))
                } else {
                    do { try receive(data) } catch {
                        finish(error: "Remote clangd sent an invalid LSP frame.")
                        return
                    }
                }
            }
        }
        if libssh2_channel_eof(channel) != 0 {
            let detail = String(decoding: stderrTail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finish(
                error: detail.isEmpty
                    ? "Remote clangd exited. Check that clangd is installed on the SSH PATH."
                    : detail)
        } else if !ready && Date().timeIntervalSince(startedAt) > 15 {
            finish(error: "Remote clangd did not start within 15 seconds.")
        }
    }

    private func receive(_ data: Data) throws {
        var data = data
        if !ready {
            startup.append(data)
            guard let range = startup.range(of: Data(RemoteClangdCommand.readyMarker.utf8)) else {
                if startup.count > 64 * 1024 {
                    throw LanguageServerFrameDecoder.FrameError.invalidHeader
                }
                return
            }
            data = Data(startup[range.upperBound...])
            startup.removeAll()
            ready = true
            emit("open")
        }
        for message in try decoder.receive(data) { emit("message", message) }
    }

    private func finish(error: String? = nil) {
        guard !stopped else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        if let channel {
            // Restore blocking mode for cleanup; a channel close must finish before SFTP reuses
            // the session. The existing NMSSH session timeout bounds these operations.
            if let rawSession = session.session {
                let blocking = libssh2_session_get_blocking(rawSession)
                libssh2_session_set_blocking(rawSession, 1)
                libssh2_channel_send_eof(channel)
                libssh2_channel_close(channel)
                libssh2_channel_free(channel)
                libssh2_session_set_blocking(rawSession, blocking)
            }
            self.channel = nil
        }
        pendingWrites.removeAll()
        emit("close", error ?? "")
    }
}
