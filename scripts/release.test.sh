#!/usr/bin/env bash
# release.sh finishes a chart release when its job is run again: a run whose gh-pages push fails
# leaves the GitHub release behind, and the next run, on a fresh clone, reuses that release instead
# of stopping at it, indexing the package bytes the release serves. It refuses a release for the tag
# that holds other assets, stops on a lookup it cannot read, creates the release beside a draft
# left for the tag, writes gh-pages from nothing on the first release, and refuses an agent release
# feed before any GitHub release exists. It packages the chart pinned to the digest the registry
# gives its appVersion image, and refuses an image the registry lacks, or an answer that is no
# digest, before any GitHub release exists.
#
# Every case runs release.sh in a fresh clone of a local bare origin, with a stub gh that logs its
# calls and keeps release state in a directory, and a stub docker that answers the registry from a
# file. Nothing reaches GitHub: the GitHub tokens are unset
# and gh's configuration and host point at nothing, so a gh call the stub does not answer fails the
# case. Needs helm, jq and git.
#
# Usage: scripts/release.test.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME=costfluent-k8s-agent
VERSION=0.0.2
TAG="v$VERSION"
REPOSITORY=example/charts
NOTES="Fixes the agent's start-up probe."
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

# Every git command here, release.sh's included, reads only the test's configuration, so a
# workstation's hooks, signing or excludes cannot change what a commit holds.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0=/dev/null
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO
export GH_CONFIG_DIR="$TMP_DIR/gh-config" GH_HOST=gh.invalid
export GITHUB_REPOSITORY="$REPOSITORY"
mkdir -p "$TMP_DIR/gh-config" "$TMP_DIR/bin"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
g() { git -c user.name=test -c user.email=test@example.test "$@"; }

cat > "$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Logs every call to $STUB_GH_LOG. A release lives in $STUB_GH_STATE/published/<tag> or
# $STUB_GH_STATE/draft/<tag>, its assets under assets/. release view finds the published release,
# else the draft, answers a missing one as gh does, exit 1 and "release not found", and fails as a
# refused token does while $STUB_GH_STATE/view-error exists. release create refuses as gh does while
# a published release holds the tag, and otherwise publishes beside any draft. release download
# copies the assets of the release view finds. Any other call fails.
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_GH_LOG"
found() {
  if [[ -d "$STUB_GH_STATE/published/$1" ]]; then echo "$STUB_GH_STATE/published/$1"
  elif [[ -d "$STUB_GH_STATE/draft/$1" ]]; then echo "$STUB_GH_STATE/draft/$1"
  else return 1; fi
}
case "${1:-} ${2:-}" in
  "release view")
    tag="$3"; shift 3
    if [[ -e "$STUB_GH_STATE/view-error" ]]; then
      printf 'HTTP 401: Bad credentials (https://api.github.com/repos/example/charts/releases/tags/%s)\nTry authenticating with:  gh auth login\n' "$tag" >&2
      exit 1
    fi
    release="$(found "$tag")" || { echo "release not found" >&2; exit 1; }
    draft=false; [[ "$release" == */draft/* ]] && draft=true
    json="$(cd "$release/assets" && for f in *; do [[ -e "$f" ]] && jq -n --arg n "$f" --argjson s "$(wc -c < "$f")" '{name: $n, size: $s}'; done | jq -s --argjson d "$draft" '{isDraft: $d, assets: .}')"
    filter=.
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) shift 2 ;;
        -q|--jq) filter="$2"; shift 2 ;;
        *) echo "stub gh: release view does not take $1" >&2; exit 1 ;;
      esac
    done
    jq -r "$filter" <<<"$json"
    ;;
  "release create")
    tag="$3"; shift 3
    assets=() notes=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) shift 2 ;;
        --notes-file) notes="$2"; shift 2 ;;
        --verify-tag) shift ;;
        -*) echo "stub gh: release create does not take $1" >&2; exit 1 ;;
        *) assets+=("$1"); shift ;;
      esac
    done
    if [[ -d "$STUB_GH_STATE/published/$tag" ]]; then
      echo "a release with the same tag name already exists: $tag" >&2
      exit 1
    fi
    mkdir -p "$STUB_GH_STATE/published/$tag/assets"
    cp -- "${assets[@]}" "$STUB_GH_STATE/published/$tag/assets/"
    cp -- "$notes" "$STUB_GH_STATE/published/$tag/notes"
    echo "https://github.com/example/charts/releases/tag/$tag"
    ;;
  "release download")
    tag="$3"; shift 3
    pattern="*" dir=.
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pattern|-p) pattern="$2"; shift 2 ;;
        --dir|-D) dir="$2"; shift 2 ;;
        --clobber) shift ;;
        *) echo "stub gh: release download does not take $1" >&2; exit 1 ;;
      esac
    done
    release="$(found "$tag")" || { echo "release not found" >&2; exit 1; }
    for f in "$release/assets/"*; do
      # shellcheck disable=SC2053 # the pattern is a glob, as gh's is
      if [[ "$(basename "$f")" == $pattern ]]; then cp -- "$f" "$dir/"; fi
    done
    ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/gh"

cat > "$TMP_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Logs every call to $STUB_DOCKER_LOG. Answers docker buildx imagetools inspect <ref> --format
# '{{json .Manifest}}' from $STUB_DOCKER_IMAGES, lines of "<ref> <digest>", as the registry does: the
# image index, whose platform manifests have digests of their own, or exit 1 for a ref it lacks. Any
# other call fails.
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_DOCKER_LOG"
if [[ $# -ne 6 || "$1 $2 $3 $5 $6" != "buildx imagetools inspect --format {{json .Manifest}}" ]]; then
  echo "stub docker: unexpected call: $*" >&2
  exit 1
fi
digest="$(awk -v ref="$4" '$1 == ref { print $2; exit }' "$STUB_DOCKER_IMAGES")"
[[ -n "$digest" ]] || { echo "ERROR: $4: not found" >&2; exit 1; }
jq -n --arg d "$digest" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", digest: $d, size: 1609, manifests: [
  {mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:\("a" * 64)", size: 673, platform: {architecture: "amd64", os: "linux"}},
  {mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:\("b" * 64)", size: 673, platform: {architecture: "arm64", os: "linux"}}]}'
STUB
chmod +x "$TMP_DIR/bin/docker"
IMAGE="$(awk '/^image:/ { i = 1; next } /^[^[:space:]#]/ { i = 0 } i && $1 == "repository:" { print $2; exit }' "$DIR/$NAME/values.yaml")"
DIGEST="sha256:$(printf 'c%.0s' {1..64})"

# origin <case dir> <appVersion> [pages]: a bare origin refusing non-fast-forward pushes, whose main
# holds the chart at $VERSION with that appVersion and the release scripts, tagged with an annotated
# $TAG whose body is $NOTES; with "pages", also a gh-pages branch indexing the chart at 0.0.1. The
# registry holds the chart's image at that appVersion with $DIGEST.
origin() {
  local case_dir="$1" app_version="$2" src="$1/src"
  mkdir -p "$case_dir/gh" "$src/scripts"
  echo "$IMAGE:$app_version $DIGEST" > "$case_dir/images"
  git init -q --bare -b main "$case_dir/origin.git"
  # A local push runs receive-pack without the GIT_CONFIG_* environment.
  git -C "$case_dir/origin.git" config maintenance.auto false
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards true
  cp -R "$DIR/$NAME" "$src/"
  cp "$DIR/scripts/release.sh" "$DIR/scripts/release-feed.sh" "$src/scripts/"
  sed -i.bak -e "s/^version:.*/version: $VERSION/" -e "s/^appVersion:.*/appVersion: \"$app_version\"/" "$src/$NAME/Chart.yaml"
  rm -f -- "$src/$NAME/Chart.yaml.bak"
  g -C "$src" init -q -b main
  g -C "$src" add -A
  g -C "$src" commit -q -m "Chart $VERSION"
  g -C "$src" tag -a "$TAG" -m "$TAG" -m "$NOTES"
  g -C "$src" push -q "$case_dir/origin.git" main "$TAG"
  [[ "${3:-}" == pages ]] || return 0
  local old="$case_dir/old" pages="$case_dir/pages"
  mkdir -p "$old/packages"
  cp -R "$DIR/$NAME" "$old/"
  sed -i.bak -e "s/^version:.*/version: 0.0.1/" -e "s/^appVersion:.*/appVersion: \"0.0.1\"/" "$old/$NAME/Chart.yaml"
  rm -f -- "$old/$NAME/Chart.yaml.bak"
  helm package "$old/$NAME" --destination "$old/packages" >/dev/null
  helm repo index "$old/packages" --url "https://github.com/$REPOSITORY/releases/download/v0.0.1"
  g init -q -b gh-pages "$pages"
  cp "$old/packages/index.yaml" "$pages/"
  printf '{"version": "0.0.1", "app_version": "0.0.1"}\n' > "$pages/$NAME.json"
  g -C "$pages" add -A
  g -C "$pages" commit -q -m "Index v0.0.1"
  g -C "$pages" push -q "$case_dir/origin.git" gh-pages
}

# release <case dir> <run> <touch time>: runs release.sh in a fresh clone of the case's origin, as
# a rerun starts on a fresh runner, with its chart files at that mtime. Sets rc; the output is in
# <case dir>/<run>.out.
release() {
  local clone="$1/$2"
  git clone -q "$1/origin.git" "$clone"
  find "$clone/$NAME" -exec touch -t "$3" {} +
  rc=0
  (cd "$clone" && PATH="$TMP_DIR/bin:$PATH" STUB_GH_STATE="$1/gh" STUB_GH_LOG="$1/gh.log" \
    STUB_DOCKER_IMAGES="$1/images" STUB_DOCKER_LOG="$1/docker.log" \
    bash scripts/release.sh "$TAG") > "$1/$2.out" 2>&1 || rc=$?
}

pages_tip() { git -C "$1/origin.git" rev-parse -q --verify refs/heads/gh-pages || echo none; }
calls() { local n; n="$(grep -c "^release $2 " "$1/gh.log" 2>/dev/null)" || true; echo "${n:-0}"; }
# entries <index file>: one "<version> <digest> <url>" line per chart version the index names.
entries() {
  awk '
    /^  - / { if (v != "") print v, d, u; v = d = u = ""; inurls = 0; sub(/^  - /, "    ") }
    /^    urls:/ { inurls = 1; next }
    /^    - / { if (inurls) u = $2; next }
    /^    [a-zA-Z]/ { inurls = 0 }
    /^    version: / { v = $2 }
    /^    digest: / { d = $2 }
    END { if (v != "") print v, d, u }
  ' "$1"
}

failed=()
fail() { echo "release [$1]: $2" >&2; [[ -z "${3:-}" ]] || tail -n 5 "$3" | sed 's/^/    /' >&2; exit 1; }
# Each case runs in a subshell, so a failing one reports and the others still run. errexit is
# switched on inside it: bash ignores it in a subshell that is an if or || condition.
run_case() {
  local status
  set +e
  ( set -e; "case_$1" )
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then echo "==> $1"; else failed+=("$1"); fi
}

case_push-refused() {
  local c="$TMP_DIR/rerun"
  origin "$c" 0.4.0 pages
  pages_tip "$c" > "$c/tip-before"
  touch "$c/refuse-pages"
  cat > "$c/origin.git/hooks/pre-receive" <<HOOK
#!/usr/bin/env bash
while read -r _ _ ref; do
  if [[ "\$ref" == refs/heads/gh-pages && -e "$c/refuse-pages" ]]; then
    rm -f -- "$c/refuse-pages"
    echo "gh-pages push refused" >&2
    exit 1
  fi
done
HOOK
  chmod +x "$c/origin.git/hooks/pre-receive"
  release "$c" first 200101010000
  [[ $rc -ne 0 ]] || fail push-refused "the run succeeded although its gh-pages push was refused" "$c/first.out"
  [[ -f "$c/gh/published/$TAG/assets/$NAME-$VERSION.tgz" ]] || fail push-refused "the release does not hold $NAME-$VERSION.tgz" "$c/first.out"
  [[ "$(calls "$c" create)" -eq 1 ]] || fail push-refused "want one release create, logged $(calls "$c" create)" "$c/first.out"
  [[ "$(pages_tip "$c")" == "$(cat "$c/tip-before")" ]] || fail push-refused "origin's gh-pages moved although its push was refused"
}

case_rerun() {
  local c="$TMP_DIR/rerun" tip index asset
  [[ -f "$c/tip-before" ]] || fail rerun "push-refused did not set up the half-done release"
  release "$c" second 200202020000
  [[ $rc -eq 0 ]] || fail rerun "the rerun exited $rc" "$c/second.out"
  [[ "$(calls "$c" create)" -eq 1 ]] || fail rerun "the rerun created the release again: $(calls "$c" create) creates logged" "$c/second.out"
  tip="$(pages_tip "$c")"
  [[ "$(git -C "$c/origin.git" rev-list --parents -n 1 "$tip")" == "$tip $(cat "$c/tip-before")" ]] ||
    fail rerun "gh-pages $tip does not have the tip from before the first run as its only parent"
  [[ "$(git -C "$c/origin.git" ls-tree --name-only gh-pages | tr '\n' ' ')" == "$NAME.json index.yaml " ]] ||
    fail rerun "gh-pages holds $(git -C "$c/origin.git" ls-tree --name-only gh-pages | tr '\n' ' '), want only index.yaml and $NAME.json"
  index="$c/index.yaml"
  git -C "$c/origin.git" show gh-pages:index.yaml > "$index"
  [[ "$(entries "$index" | grep -c "^$VERSION ")" -eq 1 ]] || fail rerun "the index does not name $VERSION exactly once: $(entries "$index" | tr '\n' ';')"
  entries "$index" | grep -q '^0\.0\.1 ' || fail rerun "the index no longer names 0.0.1: $(entries "$index" | tr '\n' ';')"
  read -r _ digest url < <(entries "$index" | grep "^$VERSION ")
  [[ "$url" == "https://github.com/$REPOSITORY/releases/download/$TAG/$NAME-$VERSION.tgz" ]] || fail rerun "the index points $VERSION at $url"
  asset="$c/gh/published/$TAG/assets/$NAME-$VERSION.tgz"
  [[ "$digest" == "$(sha256 "$asset")" ]] ||
    fail rerun "the index digest $digest is not the sha256 $(sha256 "$asset") of the package the release serves"
  [[ "$(calls "$c" download)" -eq 1 ]] || fail rerun "want one release download, logged $(calls "$c" download)" "$c/second.out"
  [[ "$(git -C "$c/origin.git" show "gh-pages:$NAME.json")" == "$(bash "$c/second/scripts/release-feed.sh" "$c/second/$NAME")" ]] ||
    fail rerun "gh-pages $NAME.json is not what release-feed.sh prints for the chart"
  [[ "$(cat "$c/gh/published/$TAG/notes")" == "$NOTES" ]] || fail rerun "the release notes are not the tag's body: $(cat "$c/gh/published/$TAG/notes")"
}

case_foreign-assets() {
  local c="$TMP_DIR/foreign-assets"
  origin "$c" 0.4.0 pages
  pages_tip "$c" > "$c/tip-before"
  mkdir -p "$c/gh/published/$TAG/assets"
  echo other > "$c/gh/published/$TAG/assets/other-$VERSION.tgz"
  release "$c" run 200101010000
  [[ $rc -ne 0 ]] || fail foreign-assets "the run indexed a release holding other-$VERSION.tgz" "$c/run.out"
  [[ "$(calls "$c" create)" -eq 0 && "$(calls "$c" download)" -eq 0 ]] ||
    fail foreign-assets "want no release create or download, logged $(calls "$c" create) and $(calls "$c" download)" "$c/run.out"
  [[ "$(pages_tip "$c")" == "$(cat "$c/tip-before")" ]] || fail foreign-assets "origin's gh-pages moved"
}

case_view-error() {
  local c="$TMP_DIR/view-error"
  origin "$c" 0.4.0 pages
  pages_tip "$c" > "$c/tip-before"
  touch "$c/gh/view-error"
  release "$c" run 200101010000
  [[ "$(calls "$c" create)" -eq 0 ]] || fail view-error "a refused lookup was read as no release: release create logged" "$c/run.out"
  [[ $rc -ne 0 ]] || fail view-error "the run succeeded although the release lookup was refused" "$c/run.out"
  [[ "$(pages_tip "$c")" == "$(cat "$c/tip-before")" ]] || fail view-error "origin's gh-pages moved"
}

case_draft() {
  local c="$TMP_DIR/draft"
  origin "$c" 0.4.0 pages
  mkdir -p "$c/gh/draft/$TAG/assets"
  echo draft > "$c/gh/draft/$TAG/assets/$NAME-$VERSION.tgz"
  release "$c" run 200101010000
  [[ "$(calls "$c" create)" -eq 1 ]] || fail draft "the run reused the draft instead of creating the release: $(calls "$c" create) creates logged" "$c/run.out"
  [[ $rc -eq 0 ]] || fail draft "the run exited $rc" "$c/run.out"
  [[ "$(calls "$c" download)" -eq 0 ]] || fail draft "the run downloaded the draft's assets" "$c/run.out"
}

case_first-release() {
  local c="$TMP_DIR/first-release"
  origin "$c" 0.4.0
  release "$c" run 200101010000
  [[ $rc -eq 0 ]] || fail first-release "the run exited $rc" "$c/run.out"
  [[ "$(git -C "$c/origin.git" ls-tree --name-only gh-pages | tr '\n' ' ')" == "$NAME.json index.yaml " ]] ||
    fail first-release "gh-pages holds $(git -C "$c/origin.git" ls-tree --name-only gh-pages | tr '\n' ' '), want only index.yaml and $NAME.json"
}

# A feed Costfluent would read as no release is refused before the GitHub release exists: refused
# after it, the release stays published with no index entry.
case_feed-refused() {
  local c="$TMP_DIR/feed-refused"
  origin "$c" dev pages
  release "$c" run 200101010000
  [[ $rc -ne 0 ]] || fail feed-refused "the run published appVersion dev" "$c/run.out"
  [[ "$(calls "$c" create)" -eq 0 ]] || fail feed-refused "the GitHub release was created before the feed was refused" "$c/run.out"
}

# The package pins the image the registry gives the appVersion now, by the index digest so every
# platform resolves, and the clone stays as tagged.
case_digest() {
  local c="$TMP_DIR/digest" asset values image
  origin "$c" 0.4.0
  release "$c" run 200101010000
  [[ $rc -eq 0 ]] || fail digest "the run exited $rc" "$c/run.out"
  [[ "$(cat "$c/docker.log")" == "buildx imagetools inspect $IMAGE:0.4.0 --format {{json .Manifest}}" ]] ||
    fail digest "want one inspect of $IMAGE:0.4.0, logged: $(tr '\n' ';' < "$c/docker.log")"
  asset="$c/gh/published/$TAG/assets/$NAME-$VERSION.tgz"
  values="$(tar -xzOf "$asset" "$NAME/values.yaml")"
  [[ "$(awk '/^image:/ { i = 1; next } /^[^[:space:]#]/ { i = 0 } i && $1 == "digest:" { print $2 }' <<<"$values")" == "\"$DIGEST\"" ]] ||
    fail digest "the package's image.digest is not $DIGEST: $(grep digest: <<<"$values")"
  image="$(helm template ci "$asset" --set agent.token=x | sed -n 's/^ *image: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
  [[ "$image" == "$IMAGE@$DIGEST" ]] || fail digest "the package runs $image, want $IMAGE@$DIGEST"
  [[ -z "$(git -C "$c/run" status --porcelain -- "$NAME")" ]] || fail digest "the run changed the chart in its checkout"
}

# An image the registry lacks, or an answer that is no digest, stops the run before the release.
case_digest-refused() {
  local c answer
  for answer in missing "sha256:latest"; do
    c="$TMP_DIR/digest-refused-${answer//[^a-z]/}"
    origin "$c" 0.4.0 pages
    if [[ "$answer" == missing ]]; then : > "$c/images"; else echo "$IMAGE:0.4.0 $answer" > "$c/images"; fi
    pages_tip "$c" > "$c/tip-before"
    release "$c" run 200101010000
    [[ $rc -ne 0 ]] || fail digest-refused "the run released with the registry answering $answer" "$c/run.out"
    [[ "$(calls "$c" create)" -eq 0 ]] || fail digest-refused "the GitHub release was created with the registry answering $answer" "$c/run.out"
    [[ "$(pages_tip "$c")" == "$(cat "$c/tip-before")" ]] || fail digest-refused "origin's gh-pages moved"
  done
}

for name in push-refused rerun foreign-assets view-error draft first-release feed-refused digest digest-refused; do
  run_case "$name"
done
[[ ${#failed[@]} -eq 0 ]] || { echo "release: failed: ${failed[*]}" >&2; exit 1; }
echo "release.sh finishes a release on a rerun, and refuses what it cannot index"
