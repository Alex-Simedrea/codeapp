//
//  Clangd.swift
//  extension
//

import Foundation

class ClangdLauncher {
    static let shared = ClangdLauncher()

    private typealias ClangdMain = @convention(c) (
        Int32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    func launchClangd(args: [String]) -> Int32 {
        let executablePath = clangdExecutablePath()
        guard FileManager.default.fileExists(atPath: executablePath) else {
            fputs(
                "clangd: bundled native clangd runtime was not found at \(executablePath)\n",
                stderr)
            return 127
        }

        setenv("CLANGD_RESOURCE_DIR", Resources.clangdResourceDir, 1)

        guard let handle = dlopen(executablePath, RTLD_NOW | RTLD_LOCAL) else {
            if let error = dlerror(), let message = String(validatingUTF8: error) {
                fputs("clangd: \(message)\n", stderr)
            }
            return 127
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "clangd_main") else {
            fputs("clangd: symbol clangd_main was not found in \(executablePath)\n", stderr)
            return 127
        }

        let entrypoint = unsafeBitCast(symbol, to: ClangdMain.self)
        let realArgs = resolvedArgs(args: args)
        var cargs = realArgs.map { strdup($0) }
        cargs.append(nil)
        defer {
            for arg in cargs {
                free(arg)
            }
        }

        return entrypoint(Int32(realArgs.count), &cargs)
    }

    private func resolvedArgs(args: [String]) -> [String] {
        var realArgs = args
        if realArgs.isEmpty {
            realArgs = ["clangd"]
        }
        if !realArgs.contains(where: { $0.hasPrefix("--resource-dir") }) {
            realArgs.append("--resource-dir=\(Resources.clangdResourceDir)")
        }
        return realArgs
    }

    private func clangdExecutablePath() -> String {
        let candidates = [
            "\(Bundle.main.privateFrameworksPath ?? "")/clangd.framework/clangd",
            "\(Resources.clangdLSP)/clangd.framework/clangd",
            "\(Resources.clangdLSP)/clangd.xcframework/ios-arm64/clangd.framework/clangd",
            "\(Resources.clangdLSP)/bin/clangd",
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
            ?? candidates[0]
    }
}
