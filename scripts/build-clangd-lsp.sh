#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

LLVM_VERSION=${LLVM_VERSION:-14.0.0}
LLVM_TAG=${LLVM_TAG:-llvmorg-$LLVM_VERSION}
BUILD_ROOT=${BUILD_ROOT:-/private/tmp/codeapp-clangd-build}
ARCHIVE="$BUILD_ROOT/llvm-project-$LLVM_VERSION.src.tar.xz"
SRC_ROOT=${SRC_ROOT:-$BUILD_ROOT/llvm-project-$LLVM_VERSION.src}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/build-ios}
NATIVE_BUILD_DIR=${NATIVE_BUILD_DIR:-$BUILD_ROOT/build-native}
MIN_IOS_VERSION=${MIN_IOS_VERSION:-16.0}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
DEST_DIR=${DEST_DIR:-$REPO_ROOT/Resources/clangd-lsp}

LLVM_URL=${LLVM_URL:-https://github.com/llvm/llvm-project/releases/download/$LLVM_TAG/llvm-project-$LLVM_VERSION.src.tar.xz}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' was not found in PATH" >&2
    exit 1
  fi
}

require_tool cmake
require_tool ninja
require_tool perl
require_tool tar

mkdir -p "$BUILD_ROOT"

if [ ! -f "$ARCHIVE" ]; then
  require_tool curl
  echo "Downloading LLVM $LLVM_VERSION source..."
  curl -L "$LLVM_URL" -o "$ARCHIVE"
fi

if [ ! -d "$SRC_ROOT" ]; then
  echo "Extracting LLVM $LLVM_VERSION source..."
  tar -xJf "$ARCHIVE" -C "$BUILD_ROOT"
fi

CLANGD_CMAKE="$SRC_ROOT/clang-tools-extra/clangd/tool/CMakeLists.txt"
CLANGD_MAIN="$SRC_ROOT/clang-tools-extra/clangd/tool/ClangdMain.cpp"
LLVM_ADD="$SRC_ROOT/llvm/cmake/modules/AddLLVM.cmake"
LLVM_OPTIONS="$SRC_ROOT/llvm/cmake/modules/HandleLLVMOptions.cmake"

if grep -q 'add_clang_tool(clangd' "$CLANGD_CMAKE"; then
  perl -0pi -e 's/add_clang_tool\(clangd/add_clang_library(clangd SHARED/' "$CLANGD_CMAKE"
fi

if ! grep -q 'FRAMEWORK TRUE OUTPUT_NAME clangd' "$CLANGD_CMAKE"; then
  cat >>"$CLANGD_CMAKE" <<'EOF'

set_target_properties(clangd PROPERTIES
  FRAMEWORK TRUE
  OUTPUT_NAME clangd
)
EOF
fi

if grep -q 'int main(int argc, char \*argv\[\])' "$CLANGD_MAIN"; then
  perl -0pi -e 's/int main\(int argc, char \*argv\[\]\)/extern "C" int clangd_main(int argc, char *argv[])/' "$CLANGD_MAIN"
fi

if grep -q 'CMAKE_SYSTEM_NAME} MATCHES "Darwin")' "$LLVM_ADD"; then
  perl -0pi -e 's/CMAKE_SYSTEM_NAME\} MATCHES "Darwin"\)/CMAKE_SYSTEM_NAME} MATCHES "Darwin|iOS")/' "$LLVM_ADD"
fi

if grep -q 'CMAKE_SYSTEM_NAME MATCHES "Darwin|FreeBSD' "$LLVM_OPTIONS"; then
  perl -0pi -e 's/CMAKE_SYSTEM_NAME MATCHES "Darwin\|FreeBSD/CMAKE_SYSTEM_NAME MATCHES "Darwin|iOS|FreeBSD/' "$LLVM_OPTIONS"
fi

cmake -G Ninja \
  -S "$SRC_ROOT/llvm" \
  -B "$NATIVE_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD='AArch64;WebAssembly' \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_ARCMT=OFF

cmake --build "$NATIVE_BUILD_DIR" --target llvm-tblgen clang-tblgen -- -j "$JOBS"

cmake -G Ninja \
  -S "$SRC_ROOT/llvm" \
  -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS_VERSION" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_SKIP_INSTALL_RULES=ON \
  -DLLVM_ENABLE_PROJECTS='clang;clang-tools-extra' \
  -DLLVM_TARGETS_TO_BUILD='AArch64;WebAssembly' \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DCLANGD_ENABLE_REMOTE=OFF \
  -DCLANGD_BUILD_XPC=OFF \
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
  -DCLANG_ENABLE_ARCMT=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_TABLEGEN="$NATIVE_BUILD_DIR/bin/llvm-tblgen" \
  -DCLANG_TABLEGEN="$NATIVE_BUILD_DIR/bin/clang-tblgen" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="arm64-apple-ios$MIN_IOS_VERSION"

perl -0pi -e 's/ -Wl,-z,defs//g; s/ -Wl,--gc-sections/ -Wl,-dead_strip/g; s/ -lrt//g' "$BUILD_DIR/build.ninja"

cmake --build "$BUILD_DIR" --target clangd -- -j "$JOBS"

FRAMEWORK=$(find "$BUILD_DIR" -type d -name 'clangd.framework' -print -quit)
BINARY=$(find "$BUILD_DIR" -type f -perm -111 -name 'clangd' -print -quit)

if [ -z "$FRAMEWORK" ] && [ -z "$BINARY" ]; then
  echo "error: clangd build output was not found under $BUILD_DIR" >&2
  exit 1
fi

rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

if [ -n "$FRAMEWORK" ]; then
  cp -R "$FRAMEWORK" "$DEST_DIR/clangd.framework"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.thebaselab.codeapp.clangd" "$DEST_DIR/clangd.framework/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleName clangd" "$DEST_DIR/clangd.framework/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LLVM_VERSION" "$DEST_DIR/clangd.framework/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LLVM_VERSION" "$DEST_DIR/clangd.framework/Info.plist" 2>/dev/null || true
else
  mkdir -p "$DEST_DIR/clangd.framework"
  cp "$BINARY" "$DEST_DIR/clangd.framework/clangd"
  cat >"$DEST_DIR/clangd.framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>clangd</string>
  <key>CFBundleIdentifier</key>
  <string>com.thebaselab.codeapp.clangd</string>
  <key>CFBundleName</key>
  <string>clangd</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>$LLVM_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$LLVM_VERSION</string>
</dict>
</plist>
EOF
fi

mkdir -p "$DEST_DIR/lib/clang"
RESOURCE_SRC="$REPO_ROOT/LanguageResources/ClangLib/usr/lib/clang/$LLVM_VERSION"

if [ -d "$RESOURCE_SRC" ]; then
  cp -R "$RESOURCE_SRC" "$DEST_DIR/lib/clang/$LLVM_VERSION"
else
  mkdir -p "$DEST_DIR/lib/clang/$LLVM_VERSION/include"
  cp -R "$SRC_ROOT/clang/lib/Headers/." "$DEST_DIR/lib/clang/$LLVM_VERSION/include"
fi

if command -v nm >/dev/null 2>&1; then
  nm -gU "$DEST_DIR/clangd.framework/clangd" | grep -q 'clangd_main'
fi

echo "Built clangd LSP resources at $DEST_DIR"
