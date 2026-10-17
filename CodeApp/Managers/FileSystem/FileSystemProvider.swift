//
//  FileSystemProvider.swift
//  Code
//
//  Created by Ken Chung on 10/4/2022.
//

import Foundation

protocol FileSystemProvider {
    static var registeredScheme: String { get }
    var gitServiceProvider: GitServiceProvider? { get }
    var searchServiceProvider: SearchServiceProvider? { get }
    var terminalServiceProvider: TerminalServiceProvider? { get }
    var portforwardServiceProvider: (any PortForwardServiceProvider)? { get }

    func contentsOfDirectory(at url: URL, completionHandler: @escaping ([URL]?, Error?) -> Void)
    func fileExists(at url: URL, completionHandler: @escaping (Bool) -> Void)
    func createDirectory(
        at: URL, withIntermediateDirectories: Bool, completionHandler: @escaping (Error?) -> Void)
    func copyItem(at: URL, to: URL, completionHandler: @escaping (Error?) -> Void)
    func moveItem(at: URL, to: URL, completionHandler: @escaping (Error?) -> Void)
    func removeItem(at: URL, completionHandler: @escaping (Error?) -> Void)
    func contents(at: URL, completionHandler: @escaping (Data?, Error?) -> Void)
    func write(
        at: URL, content: Data, atomically: Bool, overwrite: Bool,
        completionHandler: @escaping (Error?) -> Void)
    func attributesOfItem(
        at: URL, completionHandler: @escaping ([FileAttributeKey: Any?]?, Error?) -> Void)
    func quickAccessEntries(at url: URL) async throws -> [WorkspaceFileEntry]
}

struct WorkspaceFileEntry: Sendable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

extension FileSystemProvider {
    func quickAccessEntries(at url: URL) async throws -> [WorkspaceFileEntry] {
        if url.isFileURL {
            return try await Task.detached(priority: .utility) {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: Array(keys)
                ).map { child in
                    let info = try child.resourceValues(forKeys: keys)
                    let isDirectory =
                        info.isSymbolicLink == true
                        ? ((try? child.resolvingSymlinksInPath().resourceValues(forKeys: [
                            .isDirectoryKey
                        ]))?.isDirectory == true)
                        : info.isDirectory == true
                    return WorkspaceFileEntry(
                        url: child, isDirectory: isDirectory,
                        isSymbolicLink: info.isSymbolicLink == true)
                }
            }.value
        }
        let urls: [URL] = try await withCheckedThrowingContinuation { continuation in
            contentsOfDirectory(at: url) { urls, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: urls ?? [])
                }
            }
        }
        var entries: [WorkspaceFileEntry] = []
        for child in urls {
            try Task.checkCancellation()
            let attributes: [FileAttributeKey: Any?] = try await withCheckedThrowingContinuation {
                continuation in
                attributesOfItem(at: child) { attributes, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: attributes ?? [:])
                    }
                }
            }
            entries.append(
                WorkspaceFileEntry(
                    url: child,
                    isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                    isSymbolicLink: attributes[.type] as? FileAttributeType == .typeSymbolicLink))
        }
        return entries
    }
}
