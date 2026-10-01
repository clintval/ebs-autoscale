# shellcheck shell=bash
# Stubs are invoked through shellspec, which shellcheck cannot follow.
# shellcheck disable=SC2317,SC2329
Describe 'shared/utils.sh retry'
  Include shared/utils.sh

  # Keep the suite fast: no real backoff.
  sleep() { :; }

  setup() {
    CALL_LOG="$SHELLSPEC_TMPBASE/retry-calls.log"
    : > "$CALL_LOG"
  }
  Before 'setup'

  # Each helper appends to CALL_LOG on every run so examples can count attempts.
  calls() { wc -l < "$CALL_LOG" | tr -d ' '; }
  fail_until_call() {
    printf 'x\n' >> "$CALL_LOG"
    [ "$(calls)" -ge "$1" ] || return 7
  }
  fail_with_status_by_call() {
    printf 'x\n' >> "$CALL_LOG"
    return $(( 10 + $(calls) ))
  }

  It 'returns success when the command succeeds first time'
    When call retry 3 true
    The status should be success
    The stderr should equal ''
  End

  It 'returns success after transient failures and stops once it succeeds'
    When call retry 5 fail_until_call 3
    The status should be success
    The stderr should include 'attempt 2/5'
    The result of function calls should equal 3
  End

  It 'runs ATTEMPTS times, logs each failure, and returns the last status'
    When call retry 3 fail_with_status_by_call
    The status should equal 13
    The stderr should include 'command failed (status 11), attempt 1/3'
    The stderr should include 'command failed (status 12), attempt 2/3'
    The stderr should not include 'attempt 3/3'
    The result of function calls should equal 3
  End
End
