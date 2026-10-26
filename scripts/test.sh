#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests .build/ModuleCache
compiler=(xcrun swiftc -parse-as-library -module-cache-path "$PWD/.build/ModuleCache")

"${compiler[@]}" Sources/SimpleApp/ProjectStore.swift tests/StoreTests.swift -o .build/tests/StoreTests
.build/tests/StoreTests

"${compiler[@]}" Sources/SimpleApp/CodexImageService.swift tests/SyntheticImageFixture.swift tests/ServiceScenarios.swift -o .build/tests/ServiceScenarios
.build/tests/ServiceScenarios

"${compiler[@]}" Sources/SimpleApp/CodexImageService.swift Sources/SimpleApp/ProjectStore.swift Sources/SimpleApp/GenerationCoordinator.swift tests/SyntheticImageFixture.swift tests/GenerationTests.swift -o .build/tests/GenerationTests
.build/tests/GenerationTests

"${compiler[@]}" Sources/SimpleApp/GalleryOrdering.swift tests/GalleryOrderingTests.swift -o .build/tests/GalleryOrderingTests
.build/tests/GalleryOrderingTests

"${compiler[@]}" Sources/SimpleApp/ImageDeckExporter.swift tests/ExportTests.swift -o .build/tests/ExportTests
.build/tests/ExportTests
