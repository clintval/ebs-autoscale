# shellcheck shell=bash
# Shared helpers for the ebs-autoscale shell specs.

# Point the runtime scripts at the repository tree so that sourcing them
# resolves shared/utils.sh, and keep the log in the shellspec temp area so
# logerr does not try to write under /var/log during tests.
export EBS_AUTOSCALE_HOME="$SHELLSPEC_PROJECT_ROOT"
export EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE:-/tmp}/ebs-autoscale-spec.log"

# Absolute path to a repository file, e.g. script_path bin/ebs-autoscale.
script_path() {
  printf '%s' "$SHELLSPEC_PROJECT_ROOT/$1"
}

# Contents of a file under spec/fixtures, e.g. fixture describe-volumes.json.
fixture() {
  cat "$SHELLSPEC_PROJECT_ROOT/spec/fixtures/$1"
}

# Skip guard: true (success) when jq is unavailable.
no_jq() {
  ! command -v jq >/dev/null 2>&1
}

# satisfy-matcher predicate: the argument is valid JSON.
valid_json() {
  printf '%s' "$1" | jq empty >/dev/null 2>&1
}
