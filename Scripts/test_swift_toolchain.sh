#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

FAKE_SWIFT="$FIXTURE_DIR/swift"
cat >"$FAKE_SWIFT" <<'SCRIPT'
#!/usr/bin/env bash
echo "Apple Swift version 6.3.2 (swift-6.3.2-RELEASE)"
SCRIPT
chmod +x "$FAKE_SWIFT"

for shell in /bin/bash /bin/zsh; do
    "$shell" -c '
        source "$1/Scripts/swift_toolchain.sh"
        resolved="$(find_compatible_swift_tool swift "$2")"
        [[ "$resolved" == "$2" ]]
    ' promptstudio-toolchain-test "$ROOT_DIR" "$FAKE_SWIFT"
done

echo "Swift toolchain discovery tests passed"
