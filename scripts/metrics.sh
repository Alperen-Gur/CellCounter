#!/usr/bin/env bash
# metrics.sh — how much is CellCounter actually being used?
#
# Everything here comes from GitHub's own API, so the numbers are public and
# anyone can reproduce them. That matters: a figure a third party can verify is
# worth more than one from a database you control.
#
# Requires the GitHub CLI, authenticated:  gh auth login
# Traffic (views/clones) needs push access to the repo.
#
# Usage:  ./scripts/metrics.sh
set -euo pipefail

REPO="${CC_REPO:-Alperen-Gur/CellCounter}"

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

echo
echo "CellCounter — usage metrics for $REPO"
echo "$(date '+%Y-%m-%d %H:%M')"
hr

# ---- Downloads -----------------------------------------------------------
# The honest proxy for "how many installs". Cumulative and never reset.
echo "DOWNLOADS PER RELEASE"
gh api "repos/$REPO/releases" --paginate \
  --jq '.[] | "  \(.tag_name)\t\([.assets[].download_count] // [0] | add // 0)\t\(if .prerelease then "(pre)" else "" end)"' \
  | sort -k2 -rn || true

echo
echo "DOWNLOADS PER ASSET"
gh api "repos/$REPO/releases" --paginate \
  --jq '.[].assets[] | "  \(.download_count)\t\(.name)"' \
  | sort -rn || true

TOTAL=$(gh api "repos/$REPO/releases" --paginate --jq '[.[].assets[].download_count] | add // 0')
echo
echo "  TOTAL: ${TOTAL}"
hr

# ---- Repo signals --------------------------------------------------------
echo "REPO"
gh api "repos/$REPO" --jq '
  "  stars:    \(.stargazers_count)",
  "  forks:    \(.forks_count)",
  "  watchers: \(.subscribers_count)",
  "  issues:   \(.open_issues_count) open"'
hr

# ---- Traffic (needs push access; 14-day rolling window) ------------------
echo "TRAFFIC (last 14 days)"
gh api "repos/$REPO/traffic/views" \
  --jq '"  views:  \(.count) total, \(.uniques) unique"' 2>/dev/null \
  || echo "  views:  unavailable (needs push access)"
gh api "repos/$REPO/traffic/clones" \
  --jq '"  clones: \(.count) total, \(.uniques) unique"' 2>/dev/null \
  || echo "  clones: unavailable (needs push access)"

echo
echo "  Referrers:"
gh api "repos/$REPO/traffic/popular/referrers" \
  --jq '.[] | "    \(.referrer): \(.count) (\(.uniques) unique)"' 2>/dev/null \
  || echo "    unavailable"
hr

cat <<'NOTE'
Reading these honestly:

  - Clone counts are dominated by CI, mirrors and scrapers. When unique
    cloners greatly exceeds unique viewers, that traffic is not people.
  - Download counts include bots too, but far less so — they are the best
    available proxy for real installs.
  - Traffic is a rolling 14-day window. GitHub keeps no history, so if you
    care about the trend, run this monthly and save the output.
  - Deleting a release permanently destroys its download count. Mark old
    releases superseded in the notes instead.
NOTE
echo
