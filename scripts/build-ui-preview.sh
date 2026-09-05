#!/bin/bash
# Build an isolated native app from Quill's real compiled UI and fake model operations.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --scratch-path .build/validation
preview_dir="$PWD/.build/ui-evidence/QuillPreview.app"
mkdir -p "$preview_dir/Contents/MacOS"
cat > "$preview_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.quill.ui-preview</string>
<key>CFBundleName</key><string>Quill Preview</string>
<key>CFBundleExecutable</key><string>QuillPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -parse-as-library -enable-testing \
    -I .build/validation/debug/Modules \
    -I .build/validation/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/validation/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    scripts/ui-preview.swift @.build/validation/debug/quill.product/Objects.LinkFileList \
    -lc++ -o "$preview_dir/Contents/MacOS/QuillPreview"
printf '%s\n' "$preview_dir"
