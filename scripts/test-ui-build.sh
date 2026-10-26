#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$PWD/.build/ModuleCache" Sources/SimpleApp/ProjectStore.swift scripts/prepare-ui-fixture.swift -o .build/prepare-ui-fixture
.build/prepare-ui-fixture > .build/ui-fixture.json
app="$PWD/.build/映稿界面测试.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -D UI_TESTING -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$PWD/.build/ModuleCache" Sources/SimpleApp/*.swift -o "$app/Contents/MacOS/YingGaoUITest"
python3 - "$app" <<'PLIST'
import json, plistlib, sys
from pathlib import Path
fixture = json.loads(Path('.build/ui-fixture.json').read_text())
info = {'CFBundleExecutable':'YingGaoUITest','CFBundleIdentifier':'app.talk2ppt.yinggao.uitest',
        'CFBundleName':'映稿界面测试','CFBundleDisplayName':'映稿界面测试','CFBundleVersion':'1',
        'CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,
        'UITestProjectsPath':fixture['projectsRoot']}
with open(Path(sys.argv[1])/'Contents/Info.plist','wb') as stream: plistlib.dump(info,stream)
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
