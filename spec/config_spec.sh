# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/ebs-autoscale config loading'
  Include bin/ebs-autoscale

  # write_config JSON: a config whose limits.min_free_space is JSON, or that has no such key when JSON is empty.
  write_config() {
    CFG="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.json"
    LOG="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.log"
    : > "$LOG"
    printf '{"logging": {"log_file": "%s"}, "limits": {%s}}\n' "$LOG" "${1:+\"min_free_space\": $1}" > "$CFG"
    EBS_AUTOSCALE_CONFIG_FILE="$CFG"
  }

  Describe 'load_min_free_space'
    Describe 'when free-space mode is off'
      Parameters
        'a missing key' ''
        'null' 'null'
        'an empty string' '""'
        'the rendered default of 0' '"0"'
      End

      It "reads $1 as 0"
        write_config "$2"
        MIN_FREE_SPACE=7
        When call load_min_free_space
        The status should be success
        The value "$MIN_FREE_SPACE" should equal 0
      End
    End

    It 'reads a floor in GB'
      write_config '"500"'
      When call load_min_free_space
      The status should be success
      The value "$MIN_FREE_SPACE" should equal 500
    End

    It 'reads a floor given as a JSON number'
      write_config 500
      When call load_min_free_space
      The status should be success
      The value "$MIN_FREE_SPACE" should equal 500
    End

    Describe 'when the floor is malformed'
      Parameters
        'a unit suffix' '"500GB"' '500GB'
        'a negative number' '"-5"' '-5'
        'a leading zero' '"0500"' '0500'
        'a number too long for shell arithmetic' '"9999999999999999999"' '9999999999999999999'
      End

      It "fails with an error on $1"
        write_config "$2"
        When call load_min_free_space
        The status should be failure
        The stderr should include "ERR  invalid min_free_space '$3'"
      End
    End
  End

  Describe 'the daemon'
    # shellcheck disable=SC2016
    stub_imds() {
      STUB_DIR="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.bin"
      mkdir -p "$STUB_DIR"
      printf '%s\n' '#!/bin/sh' 'case "$*" in' \
        '  *api/token*) echo token ;;' \
        '  *availability-zone*) echo us-west-2a ;;' \
        '  *instance-id*) echo i-0123 ;;' \
        'esac' > "$STUB_DIR/curl"
      # A daemon that reaches its first sleep is stopped, so a missed check fails rather than hangs.
      printf '%s\n' '#!/bin/sh' 'kill -TERM "$PPID"' > "$STUB_DIR/sleep"
      chmod +x "$STUB_DIR/curl" "$STUB_DIR/sleep"
    }
    Before 'stub_imds'

    ebs_autoscale() {
      env -u SHELLSPEC_VERSION PATH="$STUB_DIR:$PATH" EBS_AUTOSCALE_CONFIG_FILE="$CFG" \
        sh "$(script_path bin/ebs-autoscale)"
    }

    It 'exits before the main loop on a malformed min_free_space'
      write_config '"500GB"'
      When run ebs_autoscale
      The status should equal 1
      The stderr should include "invalid min_free_space '500GB'"
      The contents of file "$LOG" should not include 'starting ebs-autoscale'
    End
  End
End
