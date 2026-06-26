#!/usr/bin/env bash
# Export XCTAttachment files (screenshots, etc.) from an .xcresult bundle to a
# directory, renamed to the attachment names set in the test (att.name = "01-home").
#
# Usage:
#   export-attachments.sh <result.xcresult> [output-dir]
#   export-attachments.sh                      # finds the newest *.xcresult under cwd + DerivedData
#
# Why this exists: `xcrun xcresulttool export attachments` dumps files with
# opaque names plus a manifest.json that maps each file to the human-readable
# name you set on the XCTAttachment. This script does the export and applies
# those names, so you get 01-home.png, 02-detail.png, etc.

set -euo pipefail

result="${1:-}"
outdir="${2:-./screenshots}"

if [[ -z "$result" ]]; then
  # No bundle given: pick the most recently modified .xcresult we can find.
  result="$(find . "$HOME/Library/Developer/Xcode/DerivedData" -name '*.xcresult' -type d -prune 2>/dev/null \
    | while read -r p; do printf '%s\t%s\n' "$(stat -f '%m' "$p" 2>/dev/null || echo 0)" "$p"; done \
    | sort -rn | head -1 | cut -f2-)"
  if [[ -z "$result" ]]; then
    echo "no .xcresult found; pass one explicitly: export-attachments.sh <result.xcresult> [out]" >&2
    exit 1
  fi
  echo "using newest result bundle: $result" >&2
fi

if [[ ! -e "$result" ]]; then
  echo "result bundle not found: $result" >&2
  exit 1
fi

mkdir -p "$outdir"
raw="$(mktemp -d)"
trap 'rm -rf "$raw"' EXIT

# Export every attachment plus the manifest that names them.
xcrun xcresulttool export attachments --path "$result" --output-path "$raw" >/dev/null

manifest="$raw/manifest.json"
if [[ ! -f "$manifest" ]]; then
  # Older toolchains may not emit a manifest; just copy whatever came out.
  cp "$raw"/* "$outdir"/ 2>/dev/null || true
  echo "exported (unnamed) attachments to $outdir" >&2
  exit 0
fi

# Walk the manifest, copying each exported file to its human-readable name.
# Manifest is an array of test entries, each with an `attachments` array whose
# items carry `exportedFileName` and `suggestedHumanReadableName`.
python3 - "$manifest" "$raw" "$outdir" <<'PY'
import json, os, shutil, sys
manifest, raw, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
with open(manifest) as f:
    data = json.load(f)

def entries(obj):
    if isinstance(obj, list):
        for x in obj:
            yield from entries(x)
    elif isinstance(obj, dict):
        if "exportedFileName" in obj:
            yield obj
        for v in obj.values():
            yield from entries(v)

count = 0
for a in entries(data):
    src = os.path.join(raw, a["exportedFileName"])
    if not os.path.exists(src):
        continue
    name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
    root, ext = os.path.splitext(name)
    if not ext:
        ext = os.path.splitext(a["exportedFileName"])[1] or ".png"
        name = root + ext
    dst = os.path.join(outdir, name)
    i = 1
    while os.path.exists(dst):
        dst = os.path.join(outdir, f"{root}-{i}{ext}")
        i += 1
    shutil.copy2(src, dst)
    count += 1
print(f"exported {count} attachment(s) to {outdir}", file=sys.stderr)
PY
