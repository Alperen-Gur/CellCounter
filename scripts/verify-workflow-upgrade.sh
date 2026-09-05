#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mode="${1:-all}"
export TEST_RUNNER_CELLCOUNTER_DATA_ROOT="$(mktemp -d /private/tmp/cc-workflow-tests.XXXXXX)"
selection=()
case "$mode" in
  workflow) selection=(-only-testing:CellCountingTests/AnalysisWorkflowTests) ;;
  training) selection=(-only-testing:CellCountingTests/TrainingWorkflowTests) ;;
  review) selection=(-only-testing:CellCountingTests/ReviewWorkflowTests) ;;
  performance) selection=(-only-testing:CellCountingTests/AnalysisEfficiencyTests) ;;
  models) selection=(-only-testing:CellCountingTests/ModelCatalogResponsivenessTests) ;;
  shortcuts) selection=(-only-testing:CellCountingTests/KeyboardShortcutTests) ;;
  all) selection=(-only-testing:CellCountingTests) ;;
  *) printf 'Unknown verification mode: %s\n' "$mode" >&2; exit 2 ;;
esac
mkdir -p .unlazy/workflow-upgrade/evidence
log_path=".unlazy/workflow-upgrade/evidence/$mode.log"
if ! xcodebuild test -project CellCounting.xcodeproj -scheme CellCounting \
    -destination 'platform=macOS' -derivedDataPath /private/tmp/cc-workflow-upgrade-derived \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    "${selection[@]}" >"$log_path" 2>&1; then
  tail -100 "$log_path"
  exit 1
fi
if ! /usr/bin/grep -Eq "^Test case '[^']+' passed on " "$log_path"; then
  tail -100 "$log_path"
  printf 'No executed passing tests were reported.\n' >&2
  exit 1
fi
if ! /usr/bin/grep -q '\*\* TEST SUCCEEDED \*\*' "$log_path"; then
  tail -100 "$log_path"
  exit 1
fi
printf 'WORKFLOW_UPGRADE_VERIFIED (%s)\n' "$mode"
