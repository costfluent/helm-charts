#!/usr/bin/env bash
# Print the agent release feed for a chart: {"version": <chart version>, "app_version": <appVersion>}.
#
# The release writes this beside index.yaml as costfluent-k8s-agent.json, and Costfluent reads
# app_version from it as the newest agent the chart installs, to tell a cluster its agent is
# outdated. Costfluent takes app_version only as three numbers after at most one leading v, and
# treats any other key or value as "latest unknown", which flags no cluster at all. So this refuses
# to print a feed Costfluent would read that way, and the release fails instead of publishing it.
#
# Usage: scripts/release-feed.sh <chart dir>
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <chart dir>" >&2; exit 2; }
chart="$1"

metadata="$(helm show chart "$chart")"
# helm prints the metadata it loaded, not the file: however Chart.yaml quotes a value, the output
# quotes only one that would read as another type ("1.0"), which no release version is, and the
# release check below refuses.
field() { sed -n "s/^$1: *//p" <<<"$metadata"; }
version="$(field version)"
app_version="$(field appVersion)"

release='^v?[0-9]+\.[0-9]+\.[0-9]+$'
[[ -n "$version" ]] || { echo "release-feed: $chart has no version" >&2; exit 1; }
[[ "$app_version" =~ $release ]] || {
  echo "release-feed: $chart has appVersion '$app_version', which is not an agent release (X.Y.Z or vX.Y.Z)" >&2
  exit 1
}

jq -n --arg version "$version" --arg app_version "$app_version" \
  '{version: $version, app_version: $app_version}'
