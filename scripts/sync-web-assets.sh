#!/usr/bin/env bash
# Copy the card's built assets into WebAssets/ so they get bundled
# into the .app at next build. Run after `npm run build` in the
# geo-clock-card repo and before `xcodebuild` here.
#
# Usage:
#   ./scripts/sync-web-assets.sh /path/to/geo-clock-card
#
# The path argument should be the root of the geo-clock-card repo
# checkout — the script reads `dist/*` and `docs/web/wallpaper.html`
# from it. Defaults to ~/geo-clock-card when omitted.

set -euo pipefail

CARD_REPO="${1:-$HOME/geo-clock-card}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/WebAssets"

if [[ ! -d "$CARD_REPO/dist" ]]; then
  echo "error: $CARD_REPO/dist not found. Run 'npm run build' in the card repo first." >&2
  exit 1
fi

if [[ ! -f "$CARD_REPO/docs/web/wallpaper.html" ]]; then
  echo "error: $CARD_REPO/docs/web/wallpaper.html not found." >&2
  exit 1
fi

# Staleness check: if any source file is newer than the built
# bundle, the copy we'd make is already out of date. We can't
# rebuild from here (different repo, different toolchain) so warn
# loudly — the silent variant of this drift shipped a mac app
# without the card's latest fixes once already.
if [[ -d "$CARD_REPO/src" ]]; then
  NEWER="$(find "$CARD_REPO/src" -name '*.ts' -newer "$CARD_REPO/dist/geo-clock-card.js" 2>/dev/null | head -5)"
  if [[ -n "$NEWER" ]]; then
    echo "WARNING: dist/geo-clock-card.js is OLDER than these sources:" >&2
    echo "$NEWER" >&2
    echo "Run 'npm run build' in $CARD_REPO first, then re-sync." >&2
    exit 1
  fi
fi

echo "Syncing from $CARD_REPO …"
mkdir -p "$DEST"

# Wipe the destination so removed-upstream files don't linger.
# Keep the directory itself so Xcode's folder-reference watcher
# doesn't lose track of it between syncs.
find "$DEST" -mindepth 1 -delete

# Bundle:
#   - the card's JS bundle and every imagery/GeoJSON file in dist/
#   - the wallpaper.html page itself (lives in docs/web/, not dist/)
# We exclude *.map files: source maps are dev-only and they leak
# code structure into the shipped app for zero runtime benefit.
rsync -a --exclude '*.map' "$CARD_REPO/dist/" "$DEST/"
cp "$CARD_REPO/docs/web/wallpaper.html" "$DEST/wallpaper.html"

# Provenance manifest: which card-repo commit and bundle hash this
# copy came from. Makes "is the bundled card stale?" answerable
# with a diff instead of byte-comparing JS bundles by hand.
{
  echo "synced-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "card-repo: $CARD_REPO"
  if git -C "$CARD_REPO" rev-parse HEAD >/dev/null 2>&1; then
    echo "card-commit: $(git -C "$CARD_REPO" rev-parse HEAD)"
    if [[ -n "$(git -C "$CARD_REPO" status --porcelain 2>/dev/null)" ]]; then
      echo "card-tree: dirty"
    else
      echo "card-tree: clean"
    fi
  fi
  echo "bundle-sha256: $(shasum -a 256 "$DEST/geo-clock-card.js" | awk '{print $1}')"
} > "$DEST/MANIFEST"

FILE_COUNT="$(find "$DEST" -type f | wc -l | tr -d ' ')"
DEST_BYTES="$(du -sh "$DEST" | awk '{print $1}')"
echo "Synced $FILE_COUNT files (~$DEST_BYTES total) into WebAssets/"
echo "Provenance written to WebAssets/MANIFEST"
