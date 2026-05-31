//
//  LanguageService.swift
//  Code
//
//  Created by Ken Chung on 09/08/2024.
//

import Foundation

class LanguageService {
    struct Configuration {
        let serviceIdentifier: String
        let languageIdentifier: String
        let extensions: [String]
        let args: [String]
        let documentSelector: [String]
        let initializationOptions: [String: Any]

        init(
            serviceIdentifier: String? = nil,
            languageIdentifier: String,
            extensions: [String],
            args: [String],
            documentSelector: [String]? = nil,
            initializationOptions: [String: Any] = [:]
        ) {
            self.serviceIdentifier = serviceIdentifier ?? languageIdentifier
            self.languageIdentifier = languageIdentifier
            self.extensions = extensions
            self.args = args
            self.documentSelector = documentSelector ?? [languageIdentifier]
            self.initializationOptions = initializationOptions
        }
    }

    var candidateLanguageIdentifier: String? = nil

    static let shared = LanguageService()
    static let configurations: [Configuration] = [
        Configuration(
            languageIdentifier: "python",
            extensions: ["py"],
            args: ["jedi-language-server", "-v"]),
        Configuration(
            languageIdentifier: "java",
            extensions: ["java"],
            args: ["java", "-jar", "${JAVA_LSP_FAT_JAR_PATH}"]),
        Configuration(
            serviceIdentifier: "clangd",
            languageIdentifier: "c",
            extensions: ["c"],
            args: ["clangd", "--background-index=false", "--log=info"],
            initializationOptions: ["fallbackFlags": clangdFallbackFlags()]),
        Configuration(
            serviceIdentifier: "clangd",
            languageIdentifier: "cpp",
            extensions: ["h", "hh", "hpp", "hxx", "cc", "cpp", "cxx"],
            args: ["clangd", "--background-index=false", "--log=info"],
            initializationOptions: ["fallbackFlags": clangdFallbackFlags()]),
    ]

    static func configurationFor(url: URL) -> Configuration? {
        let pathExtension = url.pathExtension.lowercased()
        return LanguageService.configurations.first(where: {
            $0.extensions.contains(pathExtension)
        })
    }

    private static func clangdFallbackFlags() -> [String] {
        let libraryURL = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let sysroot = libraryURL?.appendingPathComponent("usr").path ?? "/usr"
        return [
            "--target=wasm32-wasi",
            "--sysroot=\(sysroot)",
            "-isystem",
            "\(sysroot)/include/c++/v1",
            "-fno-exceptions",
        ]
    }
}
