#!/usr/bin/env bash

swift_tool_is_compatible() {
    local candidate="${1:?Swift tool path is required}"
    local version_line version_numbers major minor
    [[ -x "$candidate" ]] || return 1
    version_line="$("$candidate" --version 2>/dev/null | /usr/bin/head -n 1)"
    version_numbers="$(printf '%s\n' "$version_line" | /usr/bin/sed -E -n \
        's/.*Swift[[:space:]]+version[[:space:]]+([0-9]+)\.([0-9]+).*/\1 \2/p')"
    [[ -n "$version_numbers" && "$version_numbers" == *" "* ]] || return 1
    major="${version_numbers%% *}"
    minor="${version_numbers#* }"
    (( major > 6 || (major == 6 && minor >= 2) ))
}

find_compatible_swift_tool() {
    local tool="${1:?Swift tool name is required}"
    local override="${2-}"
    local candidate root

    if [[ -n "$override" ]]; then
        swift_tool_is_compatible "$override" || {
            echo "$tool override must point to Swift 6.2 or newer: $override" >&2
            return 1
        }
        printf '%s\n' "$override"
        return
    fi

    for root in "$HOME/Library/Developer/Toolchains" "/Library/Developer/Toolchains"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r candidate; do
            if swift_tool_is_compatible "$candidate"; then
                printf '%s\n' "$candidate"
                return
            fi
        done < <(/usr/bin/find "$root" \( -type f -o -type l \) -path "*/usr/bin/$tool" -print 2>/dev/null)
    done

    candidate="$(xcrun --find "$tool" 2>/dev/null || true)"
    if swift_tool_is_compatible "$candidate"; then
        printf '%s\n' "$candidate"
        return
    fi
    echo "PromptStudio requires a discoverable Swift 6.2 or newer $tool tool." >&2
    return 1
}
