#!/usr/bin/env bash

# The development key is public manifest material. Its ID is derived from SHA-256(DER) using
# Chrome's a-p nibble mapping. Production/Web Store IDs are intentionally not guessed here.
PROMPTSTUDIO_DEV_EXTENSION_ID="ejdemjnekbbpodkgfpngckkhghfeheng"

is_extension_id() {
    [[ "${1-}" =~ ^[a-p]{32}$ ]]
}

validate_production_extension_id() {
    local extension_id="${1-}"
    if ! is_extension_id "$extension_id"; then
        echo "PROMPTSTUDIO_EXTENSION_ID must be an explicit 32-character a-p extension ID." >&2
        return 1
    fi
    if [[ "$extension_id" == "$PROMPTSTUDIO_DEV_EXTENSION_ID" ]]; then
        echo "PROMPTSTUDIO_EXTENSION_ID must not be the development extension ID." >&2
        return 1
    fi
}

extension_origin_for_id() {
    local extension_id="${1:?extension ID is required}"
    is_extension_id "$extension_id" || return 1
    printf 'chrome-extension://%s/\n' "$extension_id"
}

write_capture_host_manifest_json() {
    local destination="${1:?manifest destination is required}"
    local host_path="${2:?host path is required}"
    local origin="${3:?allowed origin is required}"
    local node_bin
    node_bin="$(command -v node || true)"
    [[ -n "$node_bin" ]] || {
        echo "Node.js is required to encode the native host manifest safely." >&2
        return 1
    }
    "$node_bin" - "$destination" "$host_path" "$origin" <<'NODE'
const fs = require('node:fs');
const [destination, hostPath, origin] = process.argv.slice(2);
const manifest = {
  name: 'com.creatigo.promptstudio.capture',
  description: 'PromptStudio local web capture host',
  path: hostPath,
  type: 'stdio',
  allowed_origins: [origin],
};
fs.writeFileSync(destination, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
NODE
}

write_capture_host_allowed_origins_json() {
    local destination="${1:?configuration destination is required}"
    local origin="${2:?allowed origin is required}"
    local node_bin
    node_bin="$(command -v node || true)"
    [[ -n "$node_bin" ]] || {
        echo "Node.js is required to encode the allowed-origin configuration safely." >&2
        return 1
    }
    "$node_bin" - "$destination" "$origin" <<'NODE'
const fs = require('node:fs');
const [destination, origin] = process.argv.slice(2);
fs.writeFileSync(destination, `${JSON.stringify({ allowed_origins: [origin] }, null, 2)}\n`, { mode: 0o600 });
NODE
}
