#!/usr/bin/env bash
# release-feed.sh prints the feed Costfluent reads as the newest agent: on the committed chart, the
# chart's version and appVersion under the keys Costfluent reads; on charts whose appVersion is
# written unquoted or single-quoted, the same; for a chart at 0.2.3 installing agent 0.3.0, exactly
# the document Costfluent is tested reading; and nothing, with a failure, for an appVersion that is
# not a release, which Costfluent would read as "latest unknown".
#
# FEED_FIXTURE replaces that document with the one the reader's own test serves, when the caller
# has it. Needs helm and jq.
#
# Usage: scripts/release-feed.test.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEED="$DIR/scripts/release-feed.sh"
CHART="$DIR/costfluent-k8s-agent"
FIXTURE="${FEED_FIXTURE:-{\"version\":\"0.2.3\",\"app_version\":\"0.3.0\"\}}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/release-feed-test.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() { echo "release-feed [$1]: $2" >&2; exit 1; }

# chart <name> <version line> <appVersion line>: a copy of the committed chart with those two lines.
chart() {
  cp -R "$CHART" "$TMP_DIR/$1"
  sed -i.bak -e "s/^version:.*/$2/" -e "s/^appVersion:.*/$3/" "$TMP_DIR/$1/Chart.yaml"
  rm -f -- "$TMP_DIR/$1/Chart.yaml.bak"
  echo "$TMP_DIR/$1"
}

# expect <case> <chart dir> <feed document>: the script prints exactly that document.
expect() {
  local out
  out="$("$FEED" "$2")" || fail "$1" "release-feed.sh failed on $2"
  jq -e --argjson want "$3" '. == $want' <<<"$out" >/dev/null \
    || fail "$1" "printed $(jq -c . <<<"$out"), want $3"
  echo "==> $1: $(jq -c . <<<"$out")"
}

version="$(sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CHART/Chart.yaml")"
app_version="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CHART/Chart.yaml")"
[[ -n "$version" && -n "$app_version" ]] || fail committed "cannot read version and appVersion from $CHART/Chart.yaml"
[[ "$app_version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail committed "Chart.yaml appVersion $app_version is not a release"
committed="$(jq -nc --arg v "$version" --arg a "$app_version" '{version: $v, app_version: $a}')"
expect committed "$CHART" "$committed"

expect unquoted "$(chart unquoted 'version: 0.3.0' 'appVersion: 0.4.0')" '{"version":"0.3.0","app_version":"0.4.0"}'
expect single-quoted "$(chart single-quoted "version: '0.3.0'" "appVersion: '0.4.0'")" '{"version":"0.3.0","app_version":"0.4.0"}'
expect v-prefixed "$(chart v-prefixed 'version: 0.3.0' 'appVersion: "v0.4.0"')" '{"version":"0.3.0","app_version":"v0.4.0"}'

reader_version="$(jq -er '.version' <<<"$FIXTURE")"
reader_app_version="$(jq -er '.app_version' <<<"$FIXTURE")"
expect reader-fixture "$(chart reader "version: $reader_version" "appVersion: \"$reader_app_version\"")" "$FIXTURE"

for bad in '"0.4"' '"dev"' '0.4.0-rc.1' '"0.4.0.1"' '"+1.2.3"'; do
  name="refuse-$(tr -dc 'a-z0-9.' <<<"$bad")"
  if out="$("$FEED" "$(chart "$name" 'version: 0.3.0' "appVersion: $bad")" 2>/dev/null)"; then
    fail "$name" "appVersion $bad printed $(tr -d ' \n' <<<"$out"), but must fail: Costfluent reads it as no release"
  fi
  [[ -z "$out" ]] || fail "$name" "appVersion $bad failed but printed $out"
  echo "==> $name: refused"
done

echo "release-feed.sh prints the feed Costfluent reads, and refuses an appVersion it would not"
