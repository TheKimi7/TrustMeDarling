#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
# Builds the zip and regenerates update.json from module.prop so the version
# numbers cannot drift. Run from the repository root.
#
#   tools/release.sh            # build dist/ only
#   tools/release.sh --publish  # build, tag and create the GitHub release
set -euo pipefail

REPO_SLUG=TheKimi7/TrustMeDarling
BRANCH=main

cd "$(dirname "$0")/.."

prop() { sed -n "s/^$1=//p" module.prop; }

VERSION=$(prop version)
CODE=$(prop versionCode)
[ -n "$VERSION" ] && [ -n "$CODE" ] || { echo "module.prop: missing version/versionCode" >&2; exit 1; }

ZIP="TrustMeDarling-$VERSION.zip"
mkdir -p dist

# META-INF stays: it is the installer entry point.
EXCLUDES=(".git/*" "docs/*" "tools/*" "dist/*" "*.zip" "update.json" "*.bak")

rm -f "dist/$ZIP"
if command -v zip >/dev/null 2>&1; then
    zip -qr "dist/$ZIP" . "${EXCLUDES[@]/#/-x}" >/dev/null 2>&1 || \
    zip -qr "dist/$ZIP" . $(printf -- '-x %s ' "${EXCLUDES[@]}")
else
    python3 - "$ZIP" "${EXCLUDES[@]}" <<'PY'
import os, sys, zipfile, fnmatch
zipname, excludes = sys.argv[1], sys.argv[2:]
def skip(rel):
    return any(fnmatch.fnmatch(rel, p) or rel.startswith(p.rstrip('*')) for p in excludes)
with zipfile.ZipFile(os.path.join('dist', zipname), 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if not skip(os.path.relpath(os.path.join(root, d), '.') + '/')]
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), '.')
            if not skip(rel):
                z.write(rel, rel)
PY
fi

# Derived from module.prop, never hand-edited.
cat > update.json <<JSON
{
    "version": "$VERSION",
    "versionCode": $CODE,
    "zipUrl": "https://github.com/$REPO_SLUG/releases/download/$VERSION/$ZIP",
    "changelog": "https://raw.githubusercontent.com/$REPO_SLUG/$BRANCH/CHANGELOG.md"
}
JSON

echo "built dist/$ZIP  ($VERSION, versionCode $CODE)"
echo "regenerated update.json"

# No stale update.json, and the installer must be present.
python3 - "dist/$ZIP" <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
need = ['module.prop', 'tmd.sh', 'post-fs-data.sh', 'service.sh', 'action.sh',
        'customize.sh', 'META-INF/com/google/android/update-binary']
missing = [n for n in need if n not in names]
if missing:
    sys.exit('zip is missing: ' + ', '.join(missing))
if any(n.startswith(('docs/', 'tools/')) or n == 'update.json' for n in names):
    sys.exit('zip contains files that should be excluded')
print('zip contents verified (%d files)' % len(names))
PY

[ "${1:-}" = "--publish" ] || { echo; echo "Not published. Re-run with --publish, or follow docs/releasing.md."; exit 0; }

command -v gh >/dev/null 2>&1 || { echo "gh CLI not found" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "commit your changes first" >&2; exit 1; }

git tag -a "$VERSION" -m "$VERSION" 2>/dev/null || echo "tag $VERSION already exists"
git push origin "$BRANCH" --tags
gh release create "$VERSION" "dist/$ZIP" --title "$VERSION" --notes-file CHANGELOG.md
echo "published $VERSION"
