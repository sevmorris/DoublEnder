#!/usr/bin/env zsh
# release.sh — Build, sign, notarize, package, and publish a DoublEnder release.
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0.0
#
# Requires: xcodebuild, xcodegen, hdiutil, gh (GitHub CLI), git, xcrun

set -euo pipefail

REPO="sevmorris/DoublEnder"

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "  e.g. $0 1.0.0"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT="$PROJECT_DIR/DoublEnder.xcodeproj"
SCHEME="DoublEnder"
APP_NAME="DoublEnder"
DERIVED_DATA="/tmp/doublender_build_${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
STAGING="/tmp/doublender_dmg_${VERSION}"
DMG="/tmp/${APP_NAME}-${TAG}.dmg"
MOUNT="/tmp/doublender_verify_${VERSION}"
SIGN_IDENTITY="Developer ID Application: Seven Morris (T9RLNAXPWU)"
NOTARY_PROFILE="WoWoNotary"
ENTITLEMENTS="$PROJECT_DIR/DoublEnder/DoublEnder.entitlements"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild xcodegen hdiutil gh git codesign xcrun; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
ok "Tools present"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

if git tag | grep -q "^${TAG}$"; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# ── Version bump ──────────────────────────────────────────────────────────────
step "Bumping version to $VERSION"
CURRENT=$(awk -F'"' '/^[[:space:]]+MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_DIR/project.yml")
if [[ -z "$CURRENT" ]]; then
    fail "Could not read MARKETING_VERSION from project.yml"
fi
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "Already at $VERSION"
else
    local ESC_CURRENT ESC_VERSION
    ESC_CURRENT=$(printf '%s' "$CURRENT" | sed 's/[.[\*^$]/\\&/g')
    ESC_VERSION=$(printf '%s'  "$VERSION" | sed 's/[.[\*^$]/\\&/g')
    sed -i '' "s/MARKETING_VERSION: \"${ESC_CURRENT}\"/MARKETING_VERSION: \"${ESC_VERSION}\"/g" \
        "$PROJECT_DIR/project.yml"
    # README's "Version:" line is currently HTML (<strong>) not Markdown
    # (**); the old Markdown-only pattern silently no-op'd from v1.6.18
    # onward, leaving the display text stale. Handle both so reformatting
    # the README later doesn't quietly resurrect the bug.
    sed -i '' "s|\*\*Version:\*\* ${ESC_CURRENT}|**Version:** ${ESC_VERSION}|g" "$PROJECT_DIR/README.md"
    sed -i '' "s|<strong>Version:</strong> ${ESC_CURRENT}|<strong>Version:</strong> ${ESC_VERSION}|g" "$PROJECT_DIR/README.md"
    # Patterns accept an optional trailing letter suffix (e.g. "lr") so that
    # "DoublEnder-v1.6.18lr.dmg" or "Download v1.6.18lr" rewrite cleanly on
    # the next bump. The suffix matches the convention public DoublEnder
    # ("lr") and Cloud ("cr") share — see settings.base MARKETING_VERSION.
    sed -i '' "s|DoublEnder-v[0-9][0-9.]*[a-z]*\.dmg|DoublEnder-${TAG}.dmg|g" "$PROJECT_DIR/README.md"
    sed -i '' "s|DoublEnder-v[0-9][0-9.]*[a-z]*\.dmg|DoublEnder-${TAG}.dmg|g" "$PROJECT_DIR/docs/index.html"
    sed -i '' "s|Download v[0-9][0-9.]*[a-z]*|Download ${TAG}|g" "$PROJECT_DIR/docs/index.html"

    # Sanity-check: nothing should still reference the old version.
    if grep -E "DoublEnder-v[0-9]+\.[0-9]+\.[0-9]+[a-z]*\.dmg" \
            "$PROJECT_DIR/README.md" "$PROJECT_DIR/docs/index.html" \
            | grep -v "${TAG}\.dmg" >/dev/null 2>&1; then
        fail "Stale version references remain after rewrite — check sed patterns"
    fi

    xcodegen generate --quiet
    ok "Bumped $CURRENT → $VERSION"
    git add project.yml README.md docs/index.html DoublEnder.xcodeproj/project.pbxproj
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet
ok "Build complete"

# ── Sign ──────────────────────────────────────────────────────────────────────
step "Codesigning app"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
ok "Codesigning complete"

# ── Verify app version ────────────────────────────────────────────────────────
step "Verifying built app version"
BUILT_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
[[ "$BUILT_VERSION" == "$VERSION" ]] || \
    fail "App version mismatch: expected $VERSION, got $BUILT_VERSION"
ok "App reports $BUILT_VERSION"

# ── Stage DMG contents ────────────────────────────────────────────────────────
step "Staging DMG contents"
rm -rf "$STAGING"
mkdir "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
ok "App and Applications alias staged"

# ── Create DMG ────────────────────────────────────────────────────────────────
step "Creating DMG"
rm -f "$DMG"
hdiutil create \
    -volname "${APP_NAME} ${TAG}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -o "$DMG" \
    -quiet
ok "Created $(du -sh $DMG | cut -f1) DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
xcrun notarytool submit "$DMG" --wait --keychain-profile "$NOTARY_PROFILE"
xcrun stapler staple "$DMG"
ok "Notarization complete"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
DMG_VERSION=$(defaults read "$MOUNT/${APP_NAME}.app/Contents/Info.plist" CFBundleShortVersionString)
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
ok "DMG contains $DMG_VERSION"

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
git push
git push origin "$TAG"
ok "Pushed $TAG"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
# grep -v exits 1 when it filters everything (e.g. first release with only this tag),
# and set -e would abort — use `|| true` to keep going with an empty PREV_TAG.
PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
        | grep -v "^- Bump version" || true)
else
    CHANGES=$(git log --pretty=format:"- %s" \
        | grep -v "^- Bump version" || true)
fi
RELEASE_NOTES="### Changes
${CHANGES}"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Publish GCS permalink ─────────────────────────────────────────────────────
step "Publishing GCS download permalink"
gsutil cp "$DMG" gs://doublender-downloads/DoublEnder.dmg
gsutil acl ch -u AllUsers:R gs://doublender-downloads/DoublEnder.dmg
# Force browsers/CDNs to revalidate on every fetch. Without this, GCS's
# default Cache-Control: public, max-age=3600 means a user who downloaded
# the previous build within the last hour keeps getting it from cache even
# after we've uploaded a new one — which silently sabotages the in-app
# updater's "Download" button. release-cloud-lib.sh sets the same header
# on the Cloud manifest for the same reason.
gsutil setmeta -h "Cache-Control:no-cache" gs://doublender-downloads/DoublEnder.dmg
ok "GCS permalink updated → DoublEnder.dmg (no-cache)"

# ── Remove old releases ───────────────────────────────────────────────────────
step "Removing old releases"
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -v "^${TAG}$" || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        gh release delete "$old_tag" --repo "$REPO" --yes --cleanup-tag 2>/dev/null || true
        git tag -d "$old_tag" 2>/dev/null || true
        ok "Removed $old_tag"
    done <<< "$OLD_TAGS"
fi

# ── Clean up temp files ───────────────────────────────────────────────────────
step "Cleaning up"
rm -rf "$STAGING" "$MOUNT" "$DERIVED_DATA"
rm -f "$DMG"
ok "Temp files removed"

RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ ${APP_NAME} ${TAG} released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
