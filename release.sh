#!/usr/bin/env zsh
# release.sh — Build, sign, notarize, package, and publish a DoublEnder release.
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.6.30lr
#
# When the private Cloud overlay (project.cloud.yml) is present, also publishes
# DoublEnder Cloud at the matching numeric version so in-app updaters prompt
# across both flavours.
#
# Requires: xcodebuild, xcodegen, hdiutil, gh (GitHub CLI), git, xcrun
# Cloud step also requires: gcloud (see scripts/release-cloud-from-local.sh)

set -euo pipefail

REPO="sevmorris/DoublEnder"
TAP_REPO="sevmorris/homebrew-tap"
TAP_CASK_PATH="Casks/doublender.rb"

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
warn()  { echo "  ! $*" >&2; }

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild xcodegen hdiutil gh git codesign xcrun python3; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
python3 -c "import dmgbuild" 2>/dev/null \
    || fail "python3 module 'dmgbuild' not installed — run: python3 -m pip install dmgbuild"
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

# ── Version ordering ────────────────────────────────────────────────────────────────────────
# Nothing here stopped a release going backwards. On 2026-09-03 Magic Backup
# Machine published v1.3.9 on top of v1.4.2 — two sessions releasing from one
# clone, neither aware of the other. GitHub served the older build as "latest"
# from that moment, and because the update checker compares numerically, every
# client already on 1.4.2 read 1.3.9 as older and reported itself up to date.
# The release could not reach anyone.
#
# Tags are the record of what is actually published, and what "latest" keys on,
# so they are what this compares against. Set ALLOW_DOWNGRADE=1 to override.
step "Checking version ordering"
version_core() { printf '%s' "${1%%[-+]*}"; }
HIGHEST_TAG=$(git tag --sort=-v:refname | head -1 | sed 's/^v//')
if [[ -n "$HIGHEST_TAG" ]]; then
    NEW_CORE=$(version_core "$VERSION")
    REF_CORE=$(version_core "$HIGHEST_TAG")
    # Numeric cores only: `sort -V` places 1.7.0 ahead of 1.7.0-rc.1, backwards
    # from semver, and comparing raw strings would block any release that
    # follows its own release candidate.
    if [[ "$NEW_CORE" != "$REF_CORE" ]] \
       && [[ "$(printf '%s\n%s\n' "$NEW_CORE" "$REF_CORE" | sort -V | head -1)" == "$NEW_CORE" ]]; then
        if [[ "${ALLOW_DOWNGRADE:-0}" != "0" ]]; then
            warn "$VERSION sorts below tag v$HIGHEST_TAG — continuing, ALLOW_DOWNGRADE is set"
        else
            fail "$VERSION sorts below the highest tag v$HIGHEST_TAG. Publishing it would leave GitHub serving an older build as 'latest', and clients on $HIGHEST_TAG would be told they are up to date. Set ALLOW_DOWNGRADE=1 to override."
        fi
    fi
fi
ok "Version $VERSION does not go backwards"


# ── Shared-file gate ──────────────────────────────────────────────────────────
# Several files here are vendored copies kept byte-identical with the sibling
# app repos — these projects are deliberately independent, so there is no shared
# package to depend on. The failure mode that costs something is silent drift: a
# fix lands in one repo and the others keep the bug, which is exactly how the
# FFmpeg process hardening reached WaxOnWaxOff and left two latent crashes in
# ClipHack. Release day is when someone is looking, so it is when to say so.
#
# Absent siblings are not drift — a fresh clone or a CI checkout has none, and
# the check passes quietly. Only a content mismatch stops the release.
step "Checking shared files against sibling repos"
"$PROJECT_DIR/scripts/check-shared.sh" \
    || fail "Shared files have drifted from the sibling repos — reconcile them before releasing"
ok "Shared files in sync"

# ── Version bump ──────────────────────────────────────────────────────────────
step "Bumping version to $VERSION"
CURRENT=$(awk -F'"' '/^[[:space:]]+MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_DIR/project.yml")
if [[ -z "$CURRENT" ]]; then
    fail "Could not read MARKETING_VERSION from project.yml"
fi
# Only the project.yml rewrite is conditional. The docs rewrite below always
# runs: when the version had already been bumped by hand, the old `else` skipped
# the whole block, leaving README and docs/ pointing at the previous release with
# nothing reporting it.
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "project.yml already at $VERSION"
else
    ESC_CURRENT=$(printf '%s' "$CURRENT" | sed 's/[.[\*^$]/\\&/g')
    ESC_VERSION=$(printf '%s'  "$VERSION" | sed 's/[.[\*^$]/\\&/g')
    sed -i '' "s/MARKETING_VERSION: \"${ESC_CURRENT}\"/MARKETING_VERSION: \"${ESC_VERSION}\"/g" \
        "$PROJECT_DIR/project.yml"
    ok "project.yml $CURRENT → $VERSION"
fi

# README version badge: match any X.Y.Z[suffix] so the pattern succeeds
# even when the badge carries a different suffix than the version currently
# in project.yml (e.g. bumping suffix from "lr"→"cr" or across releases
# where the README was left stale).  Handle both the HTML (<strong>) and
# Markdown (**) variants so either format rewrites cleanly.
sed -i '' "s|\*\*Version:\*\* [0-9][0-9.]*[a-z]*|**Version:** ${VERSION}|g" "$PROJECT_DIR/README.md" "$PROJECT_DIR/docs/THEORY_OF_OPERATION.md"
sed -i '' "s|<strong>Version:</strong> [0-9][0-9.]*[a-z]*|<strong>Version:</strong> ${VERSION}|g" "$PROJECT_DIR/README.md"
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
git add project.yml README.md docs/index.html docs/THEORY_OF_OPERATION.md \
    DoublEnder.xcodeproj/project.pbxproj
if ! git diff --cached --quiet; then
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump for $VERSION"
else
    ok "Version files already current"
fi

step "Bumping build number"
BUILD_NUM=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' "$PROJECT_DIR/project.yml")
NEXT_BUILD=$((BUILD_NUM + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"${BUILD_NUM}\"/CURRENT_PROJECT_VERSION: \"${NEXT_BUILD}\"/" \
    "$PROJECT_DIR/project.yml"
xcodegen generate --quiet
git add project.yml DoublEnder.xcodeproj/project.pbxproj
git commit -m "Bump build number to ${NEXT_BUILD}"
ok "Build number ${BUILD_NUM} → ${NEXT_BUILD} (committed)"

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
# -destination 'generic/platform=macOS' is load-bearing: without it xcodebuild
# auto-selects the FIRST matching destination (on an Apple Silicon Mac that is
# {platform:macOS, arch:arm64}) and narrows the build to that one arch, silently
# overriding ARCHS = "arm64 x86_64". That shipped an arm64-only binary while the
# README promised Intel support — Intel Macs could not launch it at all, since
# Rosetta translates x86_64 to arm64 and never the reverse. "generic" means
# "Any Mac", which builds the universal binary the settings already asked for.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    -quiet
[[ -d "$APP_PATH" ]] || fail "Build did not produce $APP_PATH"

# Fail loudly rather than shipping a single-arch build again.
BUILT_ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/${APP_NAME}")
for required in arm64 x86_64; do
    [[ " $BUILT_ARCHS " == *" $required "* ]] \
        || fail "Universal build check failed: expected arm64 + x86_64, got '$BUILT_ARCHS'"
done
ok "Build complete (universal: $BUILT_ARCHS)"

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

# ── Create DMG ────────────────────────────────────────────────────────────────
# Built with dmgbuild rather than bare hdiutil so the installer window is laid
# out: background art with an arrow, the app and the Applications alias pinned
# to its endpoints, chrome hidden. dmgbuild writes the .DS_Store directly, so
# this needs no Finder, no GUI session and no automation permission — styling a
# mounted image with AppleScript would make releases fail for environment
# reasons rather than code ones.
#
# Two PATH subtleties, both load-bearing:
#   * python3 is resolved BEFORE the PATH override, so we keep the interpreter
#     that actually has dmgbuild installed rather than Xcode's bundled one.
#   * /bin is prepended for the child, because dmgbuild shells out to bare
#     `sync` and a personal ~/bin/sync would otherwise shadow the system one
#     and abort the build.
step "Creating DMG"
rm -f "$DMG"
DMG_BACKGROUND="$PROJECT_DIR/tools/dmg/dmg-background-doublender.png"
[[ -f "$DMG_BACKGROUND" ]] \
    || fail "Missing DMG background: ${DMG_BACKGROUND#$PROJECT_DIR/} — regenerate with tools/dmg/make-background.py"
PY_BIN=$(command -v python3)
PATH="/bin:/usr/bin:$PATH" "$PY_BIN" -m dmgbuild \
    -s "$PROJECT_DIR/tools/dmg/dmg-settings.py" \
    -D app="$APP_PATH" \
    -D background="$DMG_BACKGROUND" \
    "Install ${APP_NAME}" \
    "$DMG" >/dev/null
[[ -f "$DMG" ]] || fail "dmgbuild did not produce $DMG"
ok "Created $(du -sh $DMG | cut -f1) styled DMG"

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
# Resolve the tracked remote/branch so this works from any branch (e.g. a
# worktree branch whose name differs from its upstream). Fall back to
# `origin` + current branch when no upstream is configured; `-u` sets it
# on first push so subsequent runs resolve cleanly.
if UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    REMOTE="${UPSTREAM%%/*}"
    BRANCH="${UPSTREAM#*/}"
else
    REMOTE="origin"
    BRANCH=$(git branch --show-current)
fi
git push -u "$REMOTE" "HEAD:$BRANCH"
git push "$REMOTE" "$TAG"
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
# grep -v exits 1 when it filters everything (e.g. first release with only this tag),
# and set -e would abort — use `|| true` to keep going with an empty PREV_TAG.
PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- Bump build number" \
        | grep -v "^- docs:" || true)
else
    CHANGES=$(git log --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- Bump build number" \
        | grep -v "^- docs:" || true)
fi
[[ -n "$CHANGES" ]] || CHANGES="- Initial release"
RELEASE_NOTES="### Changes
${CHANGES}"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Bump Homebrew cask ────────────────────────────────────────────────────────
step "Bumping Homebrew cask"
DMG_SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
[[ -n "$DMG_SHA256" ]] || fail "Could not compute SHA256 of $DMG"
# Explicit template instead of -t: BSD and GNU mktemp disagree on -t semantics
# (GNU requires XXXXXX in the template and aborts without it).
TAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/homebrew-tap.XXXXXX")
# Use SSH origin so the push uses the same key as the main DoublEnder push
# above — the gh CLI clone defaults to HTTPS which would prompt for creds.
git clone --quiet "git@github.com:${TAP_REPO}.git" "$TAP_DIR"
CASK_FILE="$TAP_DIR/$TAP_CASK_PATH"
[[ -f "$CASK_FILE" ]] || fail "Tap repo missing $TAP_CASK_PATH"
# Match the existing version/sha256 lines regardless of suffix or hex value.
# Both lines are bare-quoted strings on dedicated lines; the regex deliberately
# spans the whole line so a stale value can't survive the rewrite.
sed -i '' "s|^  version \".*\"\$|  version \"${VERSION}\"|" "$CASK_FILE"
sed -i '' "s|^  sha256 \".*\"\$|  sha256 \"${DMG_SHA256}\"|" "$CASK_FILE"
# Verify both replacements landed — sed -i silently no-ops on a missed pattern.
grep -q "^  version \"${VERSION}\"\$" "$CASK_FILE" \
    || fail "Cask version rewrite failed"
grep -q "^  sha256 \"${DMG_SHA256}\"\$" "$CASK_FILE" \
    || fail "Cask sha256 rewrite failed"
(
    cd "$TAP_DIR"
    if [[ -z "$(git status --porcelain)" ]]; then
        # No-op if the cask was already at this version (e.g. re-run after
        # a partial failure).
        ok "Cask already at $VERSION"
    else
        git add "$TAP_CASK_PATH"
        git commit --quiet -m "Bump doublender to ${VERSION}"
        git push --quiet origin HEAD
        ok "Cask bumped to ${VERSION} (sha256 ${DMG_SHA256:0:12}…)"
    fi
)
rm -rf "$TAP_DIR"

# ── Publish GCS permalink ─────────────────────────────────────────────────────
step "Publishing GCS download permalink"
# Short TTL (60s) instead of no-cache — mirrors release-cloud-lib.sh. The
# short TTL keeps a freshly published build from being shadowed by a cached
# prior one for GCS's default 1 hour, while staying CACHEABLE: "no-cache"
# pushes the object off Google's fast media-serving path and anonymous
# downloads crawl at ~150 KB/s (~130x slower; the DMG looks hung). Verified
# empirically 2026-07-10 by A/B on the same object.
gcloud storage cp "$DMG" gs://doublender-downloads/DoublEnder.dmg \
    --cache-control="public, max-age=60"
gcloud storage objects update gs://doublender-downloads/DoublEnder.dmg \
    --add-acl-grant=entity=AllUsers,role=READER
ok "GCS permalink updated → DoublEnder.dmg (max-age=60)"

# ── Cloud release ─────────────────────────────────────────────────────────────
if [[ -f "$PROJECT_DIR/project.cloud.yml" ]]; then
    LOCAL_BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' "$PROJECT_DIR/project.yml")
    "$PROJECT_DIR/scripts/release-cloud-from-local.sh" "$VERSION" "$LOCAL_BUILD"
else
    step "Skipping Cloud release"
    ok "No project.cloud.yml — restore private overlay to publish Cloud with Local releases"
fi

# ── Remove old releases (keep the ${KEEP_RELEASES} most recent) ───────────────
KEEP_RELEASES=5
step "Removing old releases (keeping ${KEEP_RELEASES} most recent)"
# Filtered to v* so non-release tags (build-dependency releases, checkpoints)
# are never in scope for pruning by date alone.
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -E '^v[0-9]' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        # Prunes the release page and its asset, NOT the git tag. The tag is the
        # only durable pointer to what shipped: without it a version is
        # unbuildable from a clean clone and unreachable from its own history.
        # A release page is a convenience; a tag is the record.
        gh release delete "$old_tag" --repo "$REPO" --yes 2>/dev/null || true
        ok "Pruned release page for $old_tag (tag kept)"
    done <<< "$OLD_TAGS"
fi

# ── Remove old Pages deployments ─────────────────────────────────────────────
step "Removing old Pages deployments"
ALL_DEPLOY_IDS=$(gh api "repos/$REPO/deployments?environment=github-pages&per_page=100" \
    --jq '.[].id')
OLD_DEPLOY_IDS=$(echo "$ALL_DEPLOY_IDS" | tail -n +2)
if [[ -z "$OLD_DEPLOY_IDS" ]]; then
    ok "No old deployments to remove"
else
    COUNT=0
    while IFS= read -r deploy_id; do
        gh api -X POST "repos/$REPO/deployments/${deploy_id}/statuses" \
            -f state=inactive --silent 2>/dev/null || true
        gh api -X DELETE "repos/$REPO/deployments/${deploy_id}" --silent 2>/dev/null || true
        COUNT=$((COUNT + 1))
    done <<< "$OLD_DEPLOY_IDS"
    ok "Removed $COUNT old deployment(s)"
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
