#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# Three commands do the work:
#
#     swift build -c release
#     codesign --force --identifier codes.eneko.apple-pdf-mcp --sign "$IDENTITY"
#     zip -qrX apple-pdf-mcp.mcpb manifest.json icon.png server
#
# Everything else in this file is an assertion. They are here because each one guards a
# failure that is SILENT — no error at build time, just something that does not work
# later, in a way that is miserable to diagnose. They cost one line each; keep them.
#
# Only Apple/system tooling: swift, codesign, otool, zip, unzip, plutil. No Homebrew, and
# deliberately not Anthropic's `mcpb` CLI either — that needs Node, and an .mcpb is just a
# zip with manifest.json at its root.
#
# SwiftPM cannot sign: `swift build` has no signing flag, and what it emits is
# flags=0x20002 (adhoc,linker-signed) with an EMPTY designated requirement. macOS reads
# that as "signed by nobody", so the codesign step is required, not cosmetic.
set -euo pipefail

NAME="apple-pdf-mcp"
IDENTIFIER="codes.eneko.$NAME"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGE="$ROOT/extension"
OUT="$ROOT/dist/$NAME.mcpb"

# ---------------------------------------------------------------- 1. build

# Apple silicon only. A universal build (--arch arm64 --arch x86_64) doubles the bundle
# and takes ~70x longer to link, and macOS 26 is the end of the road for Intel anyway.
echo "==> Building $NAME (arm64)"
swift build -c release

BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary at $BINARY" >&2; exit 1; }

# GUARD: the embedded Info.plist is what makes this binary its own TCC subject. Without
# it macOS denies Desktop/Documents/Downloads and never shows a prompt at all.
otool -P "$BINARY" | grep -q "UsageDescription" \
  || { echo "!! Info.plist missing from $BINARY" >&2; exit 1; }

# ---------------------------------------------------------------- 2. sign

rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# Ad-hoc ("-") produces no designated requirement, so TCC anchors the grant to the
# binary's hash and re-prompts after every rebuild. Set MCPB_SIGN_IDENTITY to a real
# identity to make a grant survive rebuilds; see the README.
#
# The identifier is pinned rather than inferred: codesign would otherwise derive it from
# the embedded plist or the filename, and the designated requirement quotes it. Keep it
# in step with CFBundleIdentifier in Resources/Info.plist — TCC sees both.
IDENTITY="${MCPB_SIGN_IDENTITY:--}"
echo "==> Signing as $IDENTIFIER with identity: $IDENTITY"

SIGN_ARGS=(--force --identifier "$IDENTIFIER" --sign "$IDENTITY")

# Hardened runtime is required for notarisation, not for TCC. Opt in when distributing.
if [ "${MCPB_HARDENED:-0}" = "1" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
  [ -f "$ROOT/Resources/entitlements.plist" ] \
    && SIGN_ARGS+=(--entitlements "$ROOT/Resources/entitlements.plist")
fi

codesign "${SIGN_ARGS[@]}" "$STAGE/server/$NAME"

# GUARD: linker-signed means TCC never registers the binary, and a permission request
# just returns "not determined" with no dialog. (Do not try to confirm this from
# `log show --predicate 'subsystem == "com.apple.TCC"'` — that subsystem prints nothing
# on a normal machine either way, so an empty log proves nothing. The flags do.)
FLAGS=$(codesign -dv "$STAGE/server/$NAME" 2>&1 | grep -oE 'flags=[^ ]*' || true)
case "$FLAGS" in
  *linker-signed*) echo "!! still linker-signed ($FLAGS) — TCC will never prompt" >&2; exit 1 ;;
  *) echo "    $FLAGS" ;;
esac

# GUARD: signing rewrites the binary, so re-check rather than trusting the pass above.
otool -P "$STAGE/server/$NAME" | grep -q "UsageDescription" \
  || { echo "!! Info.plist lost during signing" >&2; exit 1; }

# Printing the designated requirement makes a silent regression to ad-hoc visible here
# rather than weeks later, when permissions start re-prompting on every rebuild.
echo "==> Designated requirement"
codesign -d -r- "$STAGE/server/$NAME" 2>&1 | grep "^designated" | sed 's/^/    /' \
  || echo "    (none — TCC will key on the cdhash and re-prompt after every rebuild)"

# ---------------------------------------------------------------- 3. pack

# GUARD: a stray comma here fails the install with an unhelpful message. plutil is
# macOS's own parser, so this needs no Python. Note `-lint` is not the flag to reach for:
# it lints property lists only and rejects JSON outright. Converting to json and throwing
# the result away parses the file, which is all this needs to do.
plutil -convert json -o /dev/null "$STAGE/manifest.json" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

echo "==> Packing"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
# -X drops resource forks and extra attributes: the archive holds only what the manifest
# describes.
( cd "$STAGE" && zip -qrX "$OUT" manifest.json icon.png server )

# GUARD: the MCPB spec does not promise the installer preserves the executable bit, so
# check the archive at least records it. Lose it and the server simply never starts.
MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install it by opening the file with Claude."
