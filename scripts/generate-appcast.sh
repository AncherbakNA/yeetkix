#!/bin/bash
# Produces local files only. Never uploads anything.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${YEETKIX_UPDATE_DOWNLOAD_PREFIX:?Set the HTTPS directory where release archives will eventually be hosted}"
python3 - <<'PY'
import os, sys, urllib.parse
u = urllib.parse.urlparse(os.environ['YEETKIX_UPDATE_DOWNLOAD_PREFIX'])
if u.scheme != 'https' or not u.hostname or u.username or u.password or u.query or u.fragment:
    sys.exit('Download prefix must be an HTTPS URL without credentials, query or fragment')
PY
directory="${1:?Pass a dedicated directory containing only release archives and release notes}"
test -d "$directory"
tool=.build/artifacts/sparkle/Sparkle/bin/generate_appcast
test -x "$tool" || { echo 'Build the app first to fetch Sparkle tools' >&2; exit 2; }
args=(--download-url-prefix "$YEETKIX_UPDATE_DOWNLOAD_PREFIX" --maximum-deltas 0)
if [ -n "${YEETKIX_ED_KEY_FILE:-}" ]; then args+=(--ed-key-file "$YEETKIX_ED_KEY_FILE"); fi
"$tool" "${args[@]}" "$directory"
