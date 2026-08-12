#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"

SWIFT_EXEC="$(find_compatible_swift_tool swift "${SWIFT_BUILD_EXEC:-}")"
TOOLCHAIN_ROOT="${SWIFT_EXEC%/usr/bin/swift}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TEST_BINARY="${TMPDIR:-/tmp}/promptstudio-pet-tests-$$"
trap 'rm -f "$TEST_BINARY"' EXIT

env PATH="$TOOLCHAIN_ROOT/usr/bin:$PATH" SDKROOT="$SDK_PATH" swiftc \
    -parse-as-library \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetCaptureTypes.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetStateMachine.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetPreferences.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetGeometry.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetHostRegistration.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetCaptureSocketServer.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetPanelController.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetView.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetStatusItemController.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetCoordinator.swift" \
    "$ROOT_DIR/Tests/PromptStudioPetTests/main.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
