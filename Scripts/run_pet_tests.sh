#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift_toolchain.sh"

SWIFT_EXEC="$(find_compatible_swift_tool swift "${SWIFT_BUILD_EXEC:-}")"
TOOLCHAIN_ROOT="${SWIFT_EXEC%/usr/bin/swift}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TEST_BINARY="${TMPDIR:-/tmp}/promptstudio-pet-tests-$$"
trap 'rm -f "$TEST_BINARY"' EXIT

PET_ASSET="$ROOT_DIR/Sources/PromptStudio/Resources/desktop-pet.png"
if [[ ! -f "$PET_ASSET" ]]; then
    echo "FAIL: desktop pet PNG is missing from app resources" >&2
    exit 1
fi

PET_WIDTH="$(sips -g pixelWidth "$PET_ASSET" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
PET_HEIGHT="$(sips -g pixelHeight "$PET_ASSET" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
PET_HAS_ALPHA="$(sips -g hasAlpha "$PET_ASSET" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')"
if [[ "$PET_WIDTH" != "512" || "$PET_HEIGHT" != "512" || "$PET_HAS_ALPHA" != "yes" ]]; then
    echo "FAIL: desktop pet PNG must be 512x512 with alpha" >&2
    exit 1
fi

env PATH="$TOOLCHAIN_ROOT/usr/bin:$PATH" SDKROOT="$SDK_PATH" swiftc \
    -parse-as-library \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetCaptureTypes.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetImageResource.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetStateMachine.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetPreferences.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetGeometry.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetNativeImageDrop.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetHostRegistration.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetCaptureSocketServer.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetPanelController.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetView.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetStatusItemController.swift" \
    "$ROOT_DIR/Sources/PromptStudio/Pet/PetCoordinator.swift" \
    "$ROOT_DIR/Tests/PromptStudioPetTests/main.swift" \
    -o "$TEST_BINARY"

PROMPTSTUDIO_PET_ASSET="$PET_ASSET" "$TEST_BINARY"
