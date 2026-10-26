#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_app="$PWD/dist/映稿.app"
native_codex="${PPT_WORKFLOW_CODEX_PATH:-}"
if [[ -z "$native_codex" ]]; then
  candidate="$(command -v codex || true)"
  # PATH may contain a symlink to the native binary or an npm JavaScript launcher.
  for _ in {1..20}; do
    [[ -L "$candidate" ]] || break
    link_target="$(readlink "$candidate")"
    if [[ "$link_target" = /* ]]; then candidate="$link_target"; else candidate="$(dirname "$candidate")/$link_target"; fi
  done
  if [[ -n "$candidate" && -x "$candidate" && -x "$(dirname "$candidate")/codex-code-mode-host" ]]; then
    native_codex="$candidate"
  elif command -v npm >/dev/null 2>&1; then
    npm_root="$(npm root -g 2>/dev/null || true)"
    if [[ -n "$npm_root" ]]; then
      native_codex="$npm_root/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
    fi
  fi
fi
if [[ ! -x "$native_codex" ]]; then
  printf '%s\n' 'Missing native Codex runtime. Set PPT_WORKFLOW_CODEX_PATH to a Codex 0.163.0 arm64 native executable.' >&2
  exit 1
fi
if [[ "$("$native_codex" --version)" != 'codex-cli 0.163.0' ]]; then
  printf '%s\n' 'Expected Codex CLI 0.163.0.' >&2; exit 1
fi
code_mode_host="$(dirname "$native_codex")/codex-code-mode-host"
if [[ ! -x "$code_mode_host" ]]; then
  printf '%s\n' 'Missing codex-code-mode-host beside Codex. Use the complete official Codex 0.163.0 runtime.' >&2
  exit 1
fi
mkdir -p dist .build/previous-app
staging_root="$(mktemp -d "$PWD/dist/.yinggao-stage.XXXXXX")"
app="$staging_root/映稿.app"
cleanup() {
  # A post-install archival failure leaves the previous bundle here intact.
  if [[ ! -f "$staging_root/.contains-previous-app" ]]; then rm -rf -- "$staging_root"; fi
}
trap cleanup EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$PWD/.build/ModuleCache" Sources/SimpleApp/*.swift -o "$app/Contents/MacOS/YingGao"
cp "$native_codex" "$app/Contents/Resources/codex"
cp "$code_mode_host" "$app/Contents/Resources/codex-code-mode-host"
chmod +x "$app/Contents/Resources/codex"
chmod +x "$app/Contents/Resources/codex-code-mode-host"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>YingGao</string>
<key>CFBundleIdentifier</key><string>app.talk2ppt.yinggao</string>
<key>CFBundleName</key><string>映稿</string>
<key>CFBundleDisplayName</key><string>映稿</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Resources/codex"
codesign --force --sign - "$app/Contents/Resources/codex-code-mode-host"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# macOS atomically exchanges the directory entries; files mapped by a running
# application are not overwritten. Keep each old bundle until a later manual cleanup.
xcrun swift - "$app" "$output_app" "$PWD/.build/previous-app" <<'SWIFT'
import Foundation
import Darwin

let args = CommandLine.arguments
let staged = URL(fileURLWithPath: args[1])
let installed = URL(fileURLWithPath: args[2])
let archiveRoot = URL(fileURLWithPath: args[3])
let fm = FileManager.default
let marker = staged.deletingLastPathComponent().appendingPathComponent(".contains-previous-app")

func requireSuccess(_ result: Int32, _ action: String) throws {
    if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(action): \(String(cString: strerror(errno)))"]) }
}

if fm.fileExists(atPath: installed.path) {
    let values = try installed.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw NSError(domain: "YingGaoBuild", code: 1, userInfo: [NSLocalizedDescriptionKey: "The existing app destination is not a regular directory."])
    }
    let archiveFolder = archiveRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: archiveFolder, withIntermediateDirectories: false)
    let archived = archiveFolder.appendingPathComponent("映稿.app")
    try Data().write(to: marker)
    let result = staged.path.withCString { source in
        installed.path.withCString { target in renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_SWAP)) }
    }
    if result != 0 {
        let error = errno
        try? fm.removeItem(at: marker)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }
    let moved = staged.path.withCString { source in archived.path.withCString { target in rename(source, target) } }
    if moved == 0 {
        try? fm.removeItem(at: marker)
        print("Previous app retained at: \(archived.path)")
    } else {
        // The replacement is installed. Preserve the previous directory if the
        // separate archive step fails, rather than treating it as disposable staging.
        print("Previous app retained in staging: \(staged.path)")
    }
} else {
    try requireSuccess(staged.path.withCString { source in installed.path.withCString { target in rename(source, target) } }, "Install app")
}
SWIFT
printf '%s\n' "$output_app"
