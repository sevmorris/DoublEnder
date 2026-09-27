#!/usr/bin/env zsh
# release.sh — Build, sign, notarize, package, and publish a DoublEnder release.
#
# Usage: ./release.sh <version> [--generated-notes]
#   e.g. ./release.sh 1.6.30lr
#
# When the private Cloud overlay (project.cloud.yml) is present, also publishes
# DoublEnder Cloud at the matching numeric version so in-app updaters prompt
# across both flavours.
#
# Requires: xcodebuild, xcodegen, hdiutil, gh (GitHub CLI), git, codesign, xcrun,
#   python3 with dmgbuild, and gcloud signed in with access to the download
#   bucket; preflight checks each. prune-deployments (mrk's bin/) is used, when
#   on PATH, to prune the Pages deployments.
# The Cloud step has its own requirements (see scripts/release-cloud-from-local.sh).

set -euo pipefail

REPO="sevmorris/DoublEnder"
# The Local download permalink: the file the in-app Download button fetches,
# overwritten by every release.
PERMALINK_BUCKET="gs://doublender-downloads"
PERMALINK="$PERMALINK_BUCKET/DoublEnder.dmg"

# ── Args ──────────────────────────────────────────────────────────────────────
# One positional argument (the version) plus optional flags in any position.
# Anything else — including no arguments, or a second positional that isn't a
# flag — still fails with usage, as it did before the flags existed.
ALLOW_GENERATED_NOTES=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --generated-notes) ALLOW_GENERATED_NOTES=1 ;;
        *)                 ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -ne 1 ]]; then
    echo "Usage: $0 <version> [--generated-notes]"
    echo "  e.g. $0 1.0.0"
    echo ""
    echo "  --generated-notes  Release without a curated release-notes file,"
    echo "                     generating notes from commit subjects instead."
    exit 1
fi

VERSION="${ARGS[1]}"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT="$PROJECT_DIR/DoublEnder.xcodeproj"
SCHEME="DoublEnder"
APP_NAME="DoublEnder"
DERIVED_DATA="/tmp/doublender_build_${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
DMG="/tmp/${APP_NAME}-${TAG}.dmg"
APP_ZIP="/tmp/${APP_NAME}-${TAG}-app.zip"
MOUNT="/tmp/doublender_verify_${VERSION}"
NOTES_FILE="$PROJECT_DIR/release-notes/${TAG}.md"
SIGN_IDENTITY="Developer ID Application: Seven Morris (T9RLNAXPWU)"
# notarytool keychain profile, shared by every sibling release script. A profile
# cannot be exported, so a new Mac needs it created again under this name:
#   xcrun notarytool store-credentials notarytool --apple-id <email> --team-id T9RLNAXPWU
# Set NOTARY_PROFILE to use another (a Mac still holding the old WoWoNotary one);
# the Cloud release reads the same variable.
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"
ENTITLEMENTS="$PROJECT_DIR/DoublEnder/DoublEnder.entitlements"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }
warn()  { echo "  ! $*" >&2; }

# Temp files only: the version and build-number bumps are committed before the
# build, so a failure leaves nothing uncommitted to revert. ${VAR:-} keeps
# `set -u` quiet on an early exit. A failure between attach and detach would
# leave the image mounted, so detach before removing the mount point.
cleanup() {
    if [[ -d "${MOUNT:-}" ]]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rm -rf -- "$MOUNT" || true
    fi
    [[ -d "${DERIVED_DATA:-}" ]] && rm -rf -- "$DERIVED_DATA" || true
    [[ -f "${DMG:-}" ]]          && rm -f  -- "$DMG"          || true
    [[ -f "${APP_ZIP:-}" ]]      && rm -f  -- "$APP_ZIP"      || true
}
# A zsh EXIT trap does not fire on a signal, so Ctrl-C or a closed terminal
# during the long notarization wait used to leave the version bump sitting in
# the working tree — the same stranded-bump state that blocked two releases on
# 2026-09-16, which the deferred commit only fixed for an ordinary failure.
# These handlers exit and let the EXIT trap do the cleanup, exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild xcodegen hdiutil gh git codesign xcrun python3 gcloud; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
python3 -c "import dmgbuild" 2>/dev/null \
    || fail "python3 module 'dmgbuild' not installed — run: python3 -m pip install dmgbuild"
# Importing dmgbuild does not prove it can run. On 2026-09-16 a pyenv Python
# built against Xcode 27's macOS 27 SDK, on macOS 26.7, imported it and then
# segfaulted on its first subprocess — dmgbuild's hdiutil call — and every DMG
# that day went out without its installer window.
python3 -c "import subprocess; subprocess.run(['/usr/bin/true'], check=True)" &>/dev/null \
    || fail "$(command -v python3) cannot start a subprocess, so dmgbuild would crash — rebuild that Python against an SDK no newer than this macOS"
ok "Tools present"

# True when this user's console session is locked. Reads IOKit's console-user
# records for our uid rather than taking the first: with more than one user
# logged in, the first record need not be ours.
screen_locked() {
    local plist i uid
    plist=$(ioreg -n Root -d1 -a 2>/dev/null) || return 1
    for i in 0 1 2 3 4 5 6 7; do
        uid=$(plutil -extract "IOConsoleUsers.$i.kCGSSessionUserIDKey" raw -o - - <<<"$plist" 2>/dev/null) || return 1
        [[ "$uid" == "$(id -u)" ]] || continue
        [[ "$(plutil -extract "IOConsoleUsers.$i.CGSSessionScreenIsLocked" raw -o - - <<<"$plist" 2>/dev/null)" == true ]]
        return
    done
    return 1
}

# A missing profile used to surface at the notarization step, after a clean
# build — which is how a new Mac found out. Asking costs one API call.
# A locked screen reads as a missing profile: notarytool keeps its credentials
# in the data-protection keychain, which locks with the screen. On 2026-09-24 a
# release stopped here at 4 a.m. and was sent looking for a profile that was
# there all along. Asked only once the check has failed, so it can never stop a
# release that would otherwise go ahead.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    screen_locked && fail "The screen is locked, so notarytool cannot read its keychain profile '$NOTARY_PROFILE' — unlock the Mac and re-run"
    fail "notarytool profile '$NOTARY_PROFILE' is missing, rejected or unreachable — create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id T9RLNAXPWU"
fi
ok "notarytool profile '$NOTARY_PROFILE' works"

# The permalink is written after the GitHub release is public, so a gcloud that
# is signed out, expired or signed in as another account would fail there: the
# release would be on GitHub, telling every copy of the app to update, while the
# permalink its Download button fetches still served the previous build, and
# neither the Cloud release nor the pruning would run. Describing the bucket
# costs one API call and proves the credentials reach it.
gcloud storage buckets describe "$PERMALINK_BUCKET" --format='value(name)' &>/dev/null \
    || fail "gcloud cannot reach $PERMALINK_BUCKET — check the account in 'gcloud auth list', or sign in with: gcloud auth login"
ok "gcloud reaches $PERMALINK_BUCKET"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

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

# The remote's tags are the record, not this clone's. A clone that has not seen
# a release — made on another Mac, or one whose tag push failed — passes a
# local-only check, then builds, notarizes and pushes the branch before the tag
# is refused, as re-runs of ClipHack and WaxOnWaxOff did on 2026-09-16. Fetching
# first lets the checks below see every published tag, and a local tag that
# disagrees with the remote makes the fetch itself fail.
git fetch --tags "$REMOTE" \
    || fail "Could not fetch tags from $REMOTE — a tag reported as rejected above points at different commits here and on $REMOTE"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# The push after the build is a fast-forward or nothing, so a remote branch with
# commits this one lacks would fail it after the notarization. Stop now instead.
if git rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null \
        && ! git merge-base --is-ancestor "$REMOTE/$BRANCH" HEAD; then
    fail "$REMOTE/$BRANCH has commits that HEAD lacks — pull before releasing"
fi
ok "HEAD contains everything on $REMOTE/$BRANCH"

# The checks above cover the public tree only. With the private overlay present,
# the Cloud release that follows builds from the overlay's files too, and they
# live in a separate repo sharing this working tree (decloud), which the dirty
# check and the fetch above never see. Uncommitted overlay edits would ship in
# the Cloud build without being recorded anywhere; an overlay behind its remote
# (a second Mac missing a change pushed from the first) would ship stale Cloud
# code without a word; a feature branch would ship unmerged code; and unpushed
# commits would ship code the overlay's remote doesn't have. Only tracked files
# count: every public file is untracked from the overlay's side.
if [[ -f "$PROJECT_DIR/project.cloud.yml" ]]; then
    OVERLAY_GIT_DIR="${DECLOUD_GIT_DIR:-$HOME/DoublEnder-cloud.git}"
    if [[ ! -d "$OVERLAY_GIT_DIR" ]]; then
        warn "No overlay repo at ${OVERLAY_GIT_DIR/#$HOME/~} — the Cloud overlay's state can't be checked"
    else
        OG=(git --git-dir="$OVERLAY_GIT_DIR" --work-tree="$PROJECT_DIR")
        [[ -z "$("${OG[@]}" status --porcelain --untracked-files=no)" ]] \
            || fail "The Cloud overlay has uncommitted changes — commit them (decloud commit) or set them aside before releasing"
        [[ "$("${OG[@]}" branch --show-current)" == "main" ]] \
            || fail "The Cloud overlay is on '$("${OG[@]}" branch --show-current)', not main — run: decloud switch main"
        "${OG[@]}" fetch --quiet origin \
            || fail "Could not fetch the Cloud overlay's remote"
        OVERLAY_BEHIND=$("${OG[@]}" rev-list --count HEAD..origin/main)
        OVERLAY_AHEAD=$("${OG[@]}" rev-list --count origin/main..HEAD)
        (( OVERLAY_BEHIND == 0 )) \
            || fail "The Cloud overlay is $OVERLAY_BEHIND commit(s) behind origin/main — run: decloud pull"
        (( OVERLAY_AHEAD == 0 )) \
            || fail "The Cloud overlay has $OVERLAY_AHEAD unpushed commit(s) — run: decloud push"
        ok "Cloud overlay clean, on main, and in sync with origin/main"
    fi
fi

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
HIGHEST_TAG=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1 | sed 's/^v//')
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

# ── Release-notes gate ────────────────────────────────────────────────────────
# The notes are read much later, at the GitHub-release step — by which point the
# branch and the tag have both been pushed. Failing there would strand a pushed
# tag with no release behind it, so the absence has to be caught here, while
# nothing has been mutated and nothing has left the machine.
#
# Without this, a forgotten notes file is invisible: the curated path announces
# itself, the generated path says nothing, and both end on the same "Release
# published" line. Shipping auto-generated notes becomes a silent default rather
# than a decision.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Curated notes present: release-notes/${TAG}.md"
elif (( ALLOW_GENERATED_NOTES )); then
    echo "\n  ⚠ --generated-notes — publishing $TAG without curated notes" >&2
    echo "      expected:  release-notes/${TAG}.md" >&2
    echo "      notes will be generated from commit subjects since the last tag" >&2
    ok "Generated notes accepted"
else
    echo "      expected:  release-notes/${TAG}.md" >&2
    fail "No curated notes for $TAG — write that file, or re-run with --generated-notes"
fi

# ── Cloud release-notes gate ──────────────────────────────────────────────────
# With the private overlay present, this run also publishes DoublEnder Cloud at
# the same numeric version (1.6.30lr → 1.6.30cr), the derivation the Cloud
# library makes. Its notes live in the overlay, at
# DoublEnderCloud/release-notes/v<cloud version>.md: what differs for Cloud,
# plus a pointer to the Local notes. Nothing publishes them — a Cloud release
# is a DMG and a version manifest — so they are the only record of what each
# Cloud build changed, and a record left for later tends not to get written.
# The Cloud step runs after this release is public, so a check there would come
# too late; this one runs before anything is built or pushed. --generated-notes
# waives it along with the Local file.
if [[ -f "$PROJECT_DIR/project.cloud.yml" ]]; then
    CLOUD_VERSION="${${VERSION#v}%%[^0-9.]*}cr"
    CLOUD_NOTES="DoublEnderCloud/release-notes/v${CLOUD_VERSION}.md"
    if [[ -f "$PROJECT_DIR/$CLOUD_NOTES" ]]; then
        ok "Cloud notes present: $CLOUD_NOTES"
    elif (( ALLOW_GENERATED_NOTES )); then
        warn "--generated-notes — releasing v${CLOUD_VERSION} without Cloud notes ($CLOUD_NOTES)"
    else
        echo "      expected:  $CLOUD_NOTES (private overlay)" >&2
        fail "No Cloud notes for v${CLOUD_VERSION} — write that file in the overlay, or re-run with --generated-notes"
    fi
fi

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

# ── Notarize app ──────────────────────────────────────────────────────────────
step "Notarizing app"
# Stapling the DMG alone leaves the app unstapled once it is dragged out, which
# is the only form anyone actually runs. Gatekeeper still passes it — it falls
# back to asking Apple — but that needs a working network on first launch. So
# the app gets its own notarization round trip and its own ticket here, before
# the DMG is built around it; the DMG is then stapled separately below.
#
# The ticket covers this exact cdhash, so this has to run after codesigning and
# before the app is copied into the DMG.
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --wait --keychain-profile "$NOTARY_PROFILE" \
    || fail "App notarization failed"
xcrun stapler staple "$APP_PATH" || fail "Stapling the app failed"
xcrun stapler validate "$APP_PATH" >/dev/null || fail "App has no valid stapled ticket"
rm -f "$APP_ZIP"
ok "App notarized and stapled"

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
#
# There is no fallback to bare hdiutil, deliberately. One was added on
# 2026-09-16 for what looked like dmgbuild crashing on a new Mac; the crash was
# the Python interpreter (see preflight), and the fallback shipped that day's
# DMGs without their installer window while still reporting a styled one.
# A DMG without its window is a failed release, not a degraded one.
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
    "$DMG" >/dev/null \
    || fail "dmgbuild failed (exit $?) — no DMG was built"
[[ -f "$DMG" ]] || fail "dmgbuild did not produce $DMG"
ok "Created $(du -sh $DMG | cut -f1) styled DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# NOTARY_PROFILE is defined at the top and proven usable in preflight.

# The image itself is signed, not only the app inside it. An unsigned DMG
# reports "no usable signature" to spctl even with a valid ticket stapled, so
# the wrapper can never be assessed — a download that looks unsigned to
# Gatekeeper while the app within it is perfectly notarized. Signing has to
# precede submission; stapling afterwards leaves the signature intact.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG" \
    || fail "Signing the DMG failed"

xcrun notarytool submit "$DMG" --wait --keychain-profile "$NOTARY_PROFILE"
xcrun stapler staple "$DMG"
ok "Notarization complete"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
DMG_VERSION=$(defaults read "$MOUNT/${APP_NAME}.app/Contents/Info.plist" CFBundleShortVersionString)
# Check the ticket on the copy that actually ships, not on the build product
# we stapled — those are the two that can drift apart. Captured before the
# detach so the volume is never left mounted on a failure.
if xcrun stapler validate "$MOUNT/${APP_NAME}.app" >/dev/null 2>&1; then
    DMG_APP_STAPLED=1
else
    DMG_APP_STAPLED=0
fi
# The installer window is these two files: the .DS_Store carrying the layout and
# the background art it points at. Without them the image opens as a plain folder.
DMG_DSSTORE=( "$MOUNT"/.DS_Store(N) )
DMG_BGART=( "$MOUNT"/.background.*(N) )
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_APP_STAPLED" == 1 ]] || \
    fail "App inside the DMG carries no notarization ticket"
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
(( ${#DMG_DSSTORE} && ${#DMG_BGART} )) || \
    fail "DMG has no installer window layout (.DS_Store and .background.* are not both present)"
ok "DMG contains $DMG_VERSION, with its installer window layout"

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# REMOTE and BRANCH were resolved in preflight. One atomic push: the branch and
# the tag land together or not at all. As two pushes, a refused tag left the
# release commit on the branch with nothing tagging it. On failure nothing has
# been published, so the tag made just above is removed and a re-run starts clean.
if ! git push --atomic -u "$REMOTE" "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"; then
    git tag -d "$TAG" >/dev/null
    fail "Push to $REMOTE failed and nothing was published — the local $TAG tag has been removed"
fi
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
# A curated description at release-notes/v<version>.md wins over the generated
# commit list. Use it when the release needs prose the log can't produce —
# licensing notes, a known-gap disclosure, an explanation of what changed and
# what deliberately didn't. Without one, fall back to subjects since the last tag.
#
# NOTES_FILE is defined with the other paths and its absence is gated in
# preflight, so reaching the generated branch here means --generated-notes was
# passed deliberately.
if [[ -f "$NOTES_FILE" ]]; then
    ok "Using curated notes: release-notes/${TAG}.md"
    gh release create "$TAG" "$DMG" \
        --repo "$REPO" \
        --title "${APP_NAME} ${TAG}" \
        --notes-file "$NOTES_FILE"
else
    # grep -v exits 1 when it filters everything (e.g. first release with only this tag),
    # and set -e would abort — use `|| true` to keep going with an empty PREV_TAG.
    # App tags only: a non-release tag (a dependency release, a checkpoint) made
    # after the last release would otherwise be taken as it and silently shorten
    # these notes.
    PREV_TAG=$(git tag --list 'v[0-9]*' --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
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
fi
ok "Release published"

# ── Publish GCS permalink ─────────────────────────────────────────────────────
step "Publishing GCS download permalink"
# Short TTL (60s) instead of no-cache — mirrors release-cloud-lib.sh. The
# short TTL keeps a freshly published build from being shadowed by a cached
# prior one for GCS's default 1 hour, while staying CACHEABLE: "no-cache"
# pushes the object off Google's fast media-serving path and anonymous
# downloads crawl at ~150 KB/s (~130x slower; the DMG looks hung). Verified
# empirically 2026-07-10 by A/B on the same object.
gcloud storage cp "$DMG" "$PERMALINK" \
    --cache-control="public, max-age=60"
gcloud storage objects update "$PERMALINK" \
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
# Delegated to prune-deployments (mrk's bin/, on PATH) rather than kept as a
# copy here, as mrk-push does. The copy this replaced deleted every deployment
# but the newest, which is wrong precisely when this runs: the push above has
# just started a Pages deployment, so the newest can still be queued, building
# or failed while the one serving the site is the older, successful one it then
# deleted — taking the published pages offline until the new build finished, or
# indefinitely if it failed. prune-deployments always protects the most recent
# successful deployment and keeps ten, as the repo-standards skill asks. The
# release is published by now, so a missing tool or a failed prune is reported
# rather than failing the run.
step "Removing old Pages deployments"
if ! command -v prune-deployments &>/dev/null; then
    warn "prune-deployments is not on PATH (it ships in mrk's bin/) — Pages deployments were not pruned"
elif ! prune-deployments --repo "$REPO" --keep 10; then
    warn "Pruning Pages deployments reported errors — the release itself is published"
fi

# ── Clean up temp files ───────────────────────────────────────────────────────
step "Cleaning up"
rm -rf "$MOUNT" "$DERIVED_DATA"
rm -f "$DMG"
ok "Temp files removed"

RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ ${APP_NAME} ${TAG} released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
