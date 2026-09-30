# shellcheck shell=bash
# Stubs are invoked indirectly by shellspec; shellcheck cannot follow the
# Include DSL.
# shellcheck disable=SC2317
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
  fail_until_call() {
    printf 'x\n' >> "$CALL_LOG"
    [ "$(wc -l < "$CALL_LOG")" -ge "$1" ] || return 7
  }
  always_fail_with_7() { printf 'x\n' >> "$CALL_LOG"; return 7; }
  calls() { wc -l < "$CALL_LOG" | tr -d ' '; }

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

  It 'returns the exit status of the command once attempts are exhausted'
    When call retry 3 always_fail_with_7
    The status should equal 7
    The stderr should be present
  End

  It 'runs the command exactly ATTEMPTS times when it never succeeds'
    When call retry 4 always_fail_with_7
    The status should equal 7
    The stderr should be present
    The result of function calls should equal 4
  End

  It 'logs the real failing status for each retried attempt'
    When call retry 3 always_fail_with_7
    The status should equal 7
    The stderr should include 'command failed (status 7), attempt 1/3'
    The stderr should include 'command failed (status 7), attempt 2/3'
    The stderr should not include 'attempt 3/3'
  End
End
