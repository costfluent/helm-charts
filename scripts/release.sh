#!/usr/bin/env bash
# Package every chart, attach the packages to the GitHub release for <tag>, and merge them into the
# Helm repository index on gh-pages, with the agent release feed beside it.
#
# The release and the gh-pages push are two writes, and the push can fail after the release exists
# (a transient error, a concurrent push). Running the job again finishes it: a published release for
# the tag is reused instead of created again, which gh refuses. When its assets are exactly the
# packages, they are downloaded over the local ones, so the index names the bytes the release
# serves; a package built on another checkout differs, because the archive carries each file's
# mtime. A published release holding any other assets stops the run before gh-pages changes. A
# draft for the tag, which an interrupted create can leave, is not reused: the release is created
# beside it, as with no release at all.
#
# Each chart is packaged with image.digest set to the digest its appVersion image has now, so what a
# released chart runs cannot change when a tag is pushed again; the image's absence, or an answer
# that is no digest, stops the run before any GitHub release exists.
#
# Needs helm, jq, git, docker with buildx and an authenticated gh. Reads GITHUB_REPOSITORY (owner/name), which the
# release URLs in the index name.
#
# Usage: scripts/release.sh <tag>
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <tag>" >&2; exit 2; }
TAG="$1"
: "${GITHUB_REPOSITORY:?names the repository the release URLs point at, as owner/name}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NOTES="$(mktemp)"
FEED="$(mktemp)"
ERROR="$(mktemp)"
STAGE="$(mktemp -d)"
trap 'rm -rf -- "$NOTES" "$FEED" "$ERROR" "$STAGE"' EXIT

# The agent release this chart installs, written beside the index and in its commit, so what
# Costfluent reads as the latest agent is what helm upgrade installs. release-feed.sh refuses a feed
# Costfluent would read as no release, and that refusal must come before the GitHub release exists.
bash scripts/release-feed.sh costfluent-k8s-agent > "$FEED"

# image_digest <chart dir>: the digest of the image the chart's values name at its appVersion, read
# as the release workflow's image check reads them. The index digest of a multi-platform image, so
# every platform it ships still resolves.
image_digest() {
  local app_version repository digest
  app_version="$(helm show chart "$1" | sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
  repository="$(helm show values "$1" | awk '/^image:/ { i = 1; next } /^[^[:space:]#]/ { i = 0 } i && $1 == "repository:" { print $2; exit }')"
  [[ -n "$app_version" && -n "$repository" ]] || { echo "release: cannot read appVersion and image.repository of $1" >&2; return 1; }
  digest="$(docker buildx imagetools inspect "$repository:$app_version" --format '{{json .Manifest}}' | jq -r '.digest // empty')" ||
    { echo "release: cannot resolve the digest of $repository:$app_version" >&2; return 1; }
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "release: $repository:$app_version resolved to '$digest', which is no sha256 digest" >&2; return 1; }
  echo "$digest"
}

# Each chart is packaged from a copy whose values carry the digest, so the checkout stays as tagged.
mkdir -p .release
for chart in */Chart.yaml; do
  dir="$(dirname "$chart")"
  digest="$(image_digest "$dir")"
  cp -Rp "$dir" "$STAGE/"
  awk -v digest="$digest" '
    /^image:/ { in_image = 1; print; next }
    /^[^[:space:]#]/ { in_image = 0 }
    in_image && /^  digest:/ { print "  digest: \"" digest "\""; written++; next }
    { print }
    END { exit written != 1 }
  ' "$dir/values.yaml" > "$STAGE/$dir/values.yaml" || { echo "release: $dir/values.yaml has no single image.digest to write" >&2; exit 1; }
  echo "release: $dir pins its image at $digest"
  helm package "$STAGE/$dir" --destination .release
done
packages="$(cd .release && printf '%s\n' *.tgz | LC_ALL=C sort)"

# The packages are release assets; gh-pages holds only index.yaml, which points at them. The tag's
# message is the reviewed release notes, and the tag is fetched again because a checkout can leave
# an annotated tag lightweight, which has no message.
git fetch --force origin "refs/tags/$TAG:refs/tags/$TAG"
git tag -l --format='%(contents:body)' "$TAG" > "$NOTES"

# gh exits 1 alike for a missing release, a token GitHub refuses, a rate limit and a server error;
# only its "release not found" means missing, and every other failure stops the release.
status=0
release="$(gh release view "$TAG" --json isDraft,assets 2>"$ERROR")" || status=$?
if (( status != 0 )); then
  { (( status == 1 )) && grep -qx 'release not found' "$ERROR"; } || {
    echo "release: could not look up the GitHub release $TAG: $(cat "$ERROR")" >&2
    exit 1
  }
  release=""
fi
if [[ -z "$release" ]] || jq -e '.isDraft' <<<"$release" >/dev/null; then
  gh release create "$TAG" .release/*.tgz --title "$TAG" --notes-file "$NOTES" --verify-tag
else
  assets="$(jq -r '.assets[].name' <<<"$release" | LC_ALL=C sort)"
  if [[ "$assets" != "$packages" ]]; then
    echo "release: the GitHub release $TAG holds assets [${assets//$'\n'/ }], not the packages [${packages//$'\n'/ }]; gh-pages is left as it is" >&2
    exit 1
  fi
  echo "release: reusing the GitHub release $TAG and indexing the packages it serves"
  gh release download "$TAG" --pattern '*.tgz' --dir .release --clobber
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
if git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
  git fetch origin gh-pages
  git worktree add .pages origin/gh-pages
else
  git worktree add --detach .pages
  git -C .pages checkout --orphan gh-pages
  git -C .pages rm -rf --quiet .
fi
existing=()
[ -f .pages/index.yaml ] && existing=(--merge .pages/index.yaml)
helm repo index .release \
  --url "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG" "${existing[@]}"
cp .release/index.yaml .pages/index.yaml
cp "$FEED" .pages/costfluent-k8s-agent.json
git -C .pages add index.yaml costfluent-k8s-agent.json
git -C .pages commit --quiet -m "Index $TAG"
git -C .pages push origin HEAD:gh-pages
