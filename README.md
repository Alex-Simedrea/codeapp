# Code App

Bringing desktop-like editing experience to iPad, available on [App Store](https://apps.apple.com/us/app/code-app/id1512938504) and [TestFlight](https://testflight.apple.com/join/EgZ8sE2P).

![Code App Screenshot](https://thebaselab.com/code/clang.png)

## About the repository

This repository contains the source code of the app. We also work on issues, listen to your feedback and publish our development plan here.

## Documentation

See [code.thebaselab.com](https://code.thebaselab.com)

## The Plan

Use [VS Code](https://github.com/microsoft/vscode) as a design template while providing key functionalities with [monaco-editor](https://github.com/microsoft/monaco-editor) and native code:

- Version Control (Git clone, commits, diff editor, push, pull and gutter indicator) ✅
- Embedded terminal (70+ commands available) ✅
- Local web development environment (Node + PHP) ✅
- Built in Python runtime ✅
- C/C++ Runtime with WebAssembly (with clang) ✅
- Local Java (OpenJDK) ✅
- SSH Support ✅
- [LSP](https://microsoft.github.io/language-server-protocol) support (Python, Java, and C/C++) ✅

## C/C++ over SSH

With the Monaco editor, **Settings → Language Service → C/C++ over SSH** runs
clangd on the connected SSH host when editing C/C++ files opened through SFTP.
This option is enabled by default. Local C/C++ remains available separately under
**Local C/C++ (experimental)** and is disabled by default.

The host must have a runnable `clangd` on its non-interactive SSH `PATH` (`clang`
alone is insufficient). The app opens a separate, non-PTY channel on the existing
SFTP connection; no remote helper, open port, or file synchronization is needed.
Unsaved changes travel over LSP. The remote project's headers, `.clangd` and
`compile_commands.json` determine parsing and indexing; the iPad's WASI flags are
not used. See [clangd project setup](https://clangd.llvm.org/installation#project-setup).

Completion with inline preview, diagnostics, hover, signature help, and navigation
use the existing Monaco LSP client. Definition targets open through SFTP, including
files outside the workspace on the same host. Disconnecting SSH or leaving the
workspace closes the remote server. If startup fails, the app shows a warning;
toggle **C/C++ over SSH** off and on to retry. Remote files never fall back to the
bundled local clangd. Python and Java continue to use their local servers.

Both app targets apply the tracked Monaco integration while building, including when resources were downloaded previously.

Development checks are documented in [scripts/tests/README.md](scripts/tests/README.md).

## Building the project

1. `git clone https://github.com/thebaselab/codeapp`
2. `./downloadFrameworks.sh`
3. Open Code.xcodeproj
4. Switch to CodeUI target if you wish to run the app on a simulator
5. Click build

The source code of the built-in languages are hosted on these repositories.
| Language | Repository |
|-----------------|-------------------|
| Python 3.9.2 | [cpython](https://github.com/holzschu/cpython/tree/3.9)|
| Clang 14.0.0 | [llvm-project](https://github.com/holzschu/llvm-project)|
| PHP 8.3.2 | [php-src](https://github.com/bummoblizard/php-src/tree/PHP-8.3.2)|
| Node.js 18.19.0 | [nodejs-mobile](https://github.com/1Conan/nodejs-mobile)|
| OpenJDK 8 | [android-openjdk-build-multiarch](https://github.com/thebaselab/android-openjdk-build-multiarch)|
