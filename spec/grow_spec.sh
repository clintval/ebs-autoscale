# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/ebs-autoscale growth attempts'
  Include bin/ebs-autoscale

  setup() {
    MAX_EBS_VOLUME_COUNT=2; MAX_LOGICAL_VOLUME_SIZE=1000
    MIN_EBS_VOLUME_SIZE=150; MAX_EBS_VOLUME_SIZE=1500
    INITIAL_UTILIZATION_THRESHOLD=50
    MOUNTPOINT=/scratch; FILE_SYSTEM=lvm.ext4; LVM_VG=vg; LVM_LV=lv
    INSTANCE_ID='i-0123'
    AWS_REGION=us-west-2
    GROW_RETRY_DELAY=0; NEXT_GROW_ATTEMPT=0
    NUM_DEVICES=0; THRESHOLD=50; NOW=1000
    CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.aws-calls"
    CREATES="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.creates"
    CREATE_OUTPUT="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.create-output"
    CREATE_VOLUME="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.create-ebs-volume"
    : > "$CALLS"; : > "$CREATES"
    export CALLS CREATES CREATE_OUTPUT
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho create >> "$CREATES"\ncat "$CREATE_OUTPUT"\n' > "$CREATE_VOLUME"
    chmod +x "$CREATE_VOLUME"
    set_volumes 1 100
    create_succeeds
    GROW_RC=0
    now_seconds() { printf '%s' "$NOW"; }
    sleep() { :; }
    grow_filesystem() { return "$GROW_RC"; }
    # Serves describe-volumes from VOLUMES_JSON and records each call.
    aws() {
      printf '%s\n' "$*" >> "$CALLS"
      printf '%s' "$VOLUMES_JSON"
    }
  }
  Before 'setup'

  # set_volumes COUNT SIZE_GB: COUNT autoscaled volumes of SIZE_GB each,
  # attached to this instance.
  set_volumes() {
    VOLUMES_JSON=$(jq -nc --argjson n "$1" --argjson size "$2" --arg iid "$INSTANCE_ID" \
      '{Volumes: [range($n) | {Size: $size, Tags: [{Key: "amazon-ebs-autoscale-creation-time", Value: "t"}], Attachments: [{InstanceId: $iid}]}]}')
  }
  # create-ebs-volume --skip-delete-on-termination prints "<device> <bdm_device> <volume_id>".
  create_succeeds() { echo "/dev/nvme1n1 /dev/sdf vol-0abc" > "$CREATE_OUTPUT"; }
  create_fails() { : > "$CREATE_OUTPUT"; }
  # create_exits STATUS: create-ebs-volume prints CREATE_OUTPUT, then exits STATUS.
  # shellcheck disable=SC2016
  create_exits() { printf '#!/bin/sh\necho create >> "$CREATES"\ncat "$CREATE_OUTPUT"\nexit %s\n' "$1" > "$CREATE_VOLUME"; }
  create_at_limit() { create_fails; create_exits 3; }
  create_errors() { create_fails; create_exits 1; }
  create_count() { wc -l < "$CREATES" | tr -d ' '; }
  # A successful grow also sets DeleteOnTermination; count only the describe calls
  # (grep -c still prints 0 when it exits 1 on no match).
  aws_call_count() { grep -c describe-volumes "$CALLS" || true; }

  Describe 'once a growth limit is reached'
    # The first attempt discovers the limit; ticks over the next 5 minutes
    # must not call EC2.
    aws_calls_on_later_ticks() {
      attempt_grow 95
      : > "$CALLS"
      NOW=1100; attempt_grow 95; NOW=1299; attempt_grow 95
      aws_call_count
    }

    It 'makes no aws calls for the next 5 minutes at the attached volume limit'
      set_volumes 2 100
      When call aws_calls_on_later_ticks
      The output should equal 0
    End

    It 'makes no aws calls for the next 5 minutes at the autoscaled size limit'
      set_volumes 1 1000
      When call aws_calls_on_later_ticks
      The output should equal 0
    End

    It 'does not try to create a volume at the limit'
      set_volumes 2 100
      When call attempt_grow 95
      The status should be success
      The value "$(create_count)" should equal 0
    End

    It 'checks again after 5 minutes and grows if the limit has lifted'
      set_volumes 2 100
      attempt_grow 95
      set_volumes 1 100
      NOW=1300
      When call attempt_grow 95
      The status should be success
      The value "$(create_count)" should equal 1
    End

    It 'reports that ticks during the wait were skipped'
      set_volumes 2 100
      attempt_grow 95
      When call attempt_grow 95
      The status should equal 1
    End
  End

  Describe 'when create-ebs-volume reports a limit'
    It 'reports a growth limit'
      create_at_limit
      When call add_space 1 100
      The status should equal 2
    End

    It 'waits 5 minutes before trying again'
      create_at_limit
      attempt_grow 95
      NOW=1299
      When call attempt_grow 95
      The status should equal 1
      The value "$(create_count)" should equal 1
    End

    It 'tries again after 5 minutes'
      create_at_limit
      attempt_grow 95
      NOW=1300
      When call attempt_grow 95
      The status should be success
      The value "$(create_count)" should equal 2
    End
  End

  Describe 'when create-ebs-volume exits 1'
    It 'reports a failure rather than a growth limit'
      create_errors
      When call add_space 1 100
      The status should equal 1
      The stderr should include 'failed to create or attach a volume (status 1)'
    End

    It 'takes the failure backoff'
      create_errors
      attempt_grow 95 2>/dev/null
      NOW=1010
      When call attempt_grow 95
      The stderr should include 'growing failed; next attempt in 20s'
      The value "$(create_count)" should equal 2
    End
  End

  Describe 'near the maximum total size'
    record_create_args() {
      MAX_EBS_VOLUME_COUNT=16; MAX_LOGICAL_VOLUME_SIZE=8000
      # shellcheck disable=SC2016
      printf '#!/bin/sh\necho "$*" >> "$CREATES"\ncat "$CREATE_OUTPUT"\n' > "$CREATE_VOLUME"
    }
    Before 'record_create_args'
    requested_sizes() { sed -n 's/.*--size \([0-9]*\).*/\1/p' "$CREATES"; }

    # With 11 devices the next step is 1500 GB.
    Describe 'with room for at least the minimum volume size'
      Parameters
        6500 1500
        7700 300
        7850 150
      End
      Example "requests ${2} GB at ${1} of 8000 GB"
        When call add_space 11 "$1"
        The status should be success
        The result of function requested_sizes should equal "$2"
      End
    End

    Describe 'with less than the minimum volume size left'
      Parameters
        7851
        7900
      End
      Example "stops at a growth limit at ${1} of 8000 GB"
        When call add_space 11 "$1"
        The status should equal 2
        The value "$(create_count)" should equal 0
      End
    End

    It 'stops at a growth limit at the max even with no minimum volume size'
      MIN_EBS_VOLUME_SIZE=0
      When call add_space 11 8000
      The status should equal 2
      The value "$(create_count)" should equal 0
    End

    It 'passes its max total size to create-ebs-volume'
      When call add_space 11 100
      The status should be success
      The contents of file "$CREATES" should include '--max-total-created-size 8000'
    End

    Describe 'the log line when not growing'
      fresh_log() {
        EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.log"
        : > "$EBS_AUTOSCALE_LOG_FILE"
      }
      Before 'fresh_log'

      It 'names the minimum volume size when too little is left for it'
        When call add_space 11 7900
        The status should equal 2
        The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'autoscaled=7900/8000GB min=150GB'
      End

      It 'leaves the minimum out when the device count stops growth'
        When call add_space 16 100
        The status should equal 2
        The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'devices=16/16'
        The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'min='
      End
    End

    Describe 'when create-ebs-volume refuses at the size limit'
      # Runs the real create-ebs-volume against stub IMDS and EC2 that already count
      # 7900 GB; its config allows 10000 GB, so only the daemon's 8000 GB refuses.
      # shellcheck disable=SC2016
      real_create_volume() {
        local bin="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.real-create-bin"
        local cfg="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.real-create-config.json"
        mkdir -p "$bin"
        echo '{"volume": {"type": "gp3", "iops": 3000, "throughput": 125, "encrypted": 1},
          "limits": {"max_logical_volume_size": 10000, "max_ebs_volume_count": 16}}' > "$cfg"
        printf '%s\n' '#!/bin/sh' 'case "$*" in' \
          '  *api/token*) echo token ;;' \
          '  *availability-zone*) echo us-west-2a ;;' \
          '  *instance-id*) echo i-0123 ;;' \
          'esac' > "$bin/curl"
        printf '%s\n' '#!/bin/sh' 'case "$*" in' \
          "  *describe-volumes*) jq -nc '{Volumes: [{Size: 7900}]}' ;;" \
          '  *) exit 1 ;;' \
          'esac' > "$bin/aws"
        chmod +x "$bin/curl" "$bin/aws"
        printf '%s\n' '#!/bin/sh' \
          "exec env -u SHELLSPEC_VERSION PATH=\"${bin}:\$PATH\" EBS_AUTOSCALE_CONFIG_FILE=\"${cfg}\" sh \"$(script_path bin/create-ebs-volume)\" \"\$@\"" \
          > "$CREATE_VOLUME"
      }
      Before 'real_create_volume'

      It 'makes add_space report a growth limit'
        When call add_space 11 6490
        The status should equal 2
        The stderr should include 'would exceed the maximum total EBS volume size (7900 of 8000 GB created)'
      End

      It 'makes the daemon wait 5 minutes before trying again'
        set_volumes 11 590
        When call attempt_grow 95
        The status should be success
        The stderr should include 'would exceed the maximum total EBS volume size'
        The value "$NEXT_GROW_ATTEMPT" should equal 1300
      End
    End
  End

  Describe 'after a successful grow'
    It 'advances the device count and threshold'
      set_volumes 3 100
      MAX_EBS_VOLUME_COUNT=16
      When call attempt_grow 95
      The status should be success
      The value "$NUM_DEVICES $THRESHOLD" should equal '4 80'
    End
  End

  Describe 'when the refreshed device count raises the threshold'
    It 'does not grow while utilization is under the new threshold'
      MAX_EBS_VOLUME_COUNT=16
      set_volumes 5 100
      When call attempt_grow 60
      The status should be success
      The value "$(create_count)" should equal 0
      The value "$NUM_DEVICES $THRESHOLD" should equal '5 80'
    End
  End

  Describe 'when the startup query fails'
    It 'does not grow on the fallback threshold once the device count is known'
      MAX_EBS_VOLUME_COUNT=16
      set_volumes 5 100
      MOUNTPOINT="$SHELLSPEC_TMPBASE"; LOG_INTERVAL=1; DETECTION_INTERVAL=2
      read_fs_stats() { echo '100 60 40 60'; }
      sleep() { exit 0; }
      aws() {
        printf '%s\n' "$*" >> "$CALLS"
        [ "$(aws_call_count)" -gt 1 ] || return 1
        printf '%s' "$VOLUMES_JSON"
      }
      When run run_daemon
      The status should be success
      The value "$(create_count)" should equal 0
      The value "$(aws_call_count)" should equal 2
    End
  End

  Describe 'when the log cannot be written'
    It 'still reports a successful grow'
      EBS_AUTOSCALE_LOG_FILE=/nonexistent/ebs-autoscale.log
      When call add_space 1 100
      The status should be success
      The stderr should be present
    End
  End

  Describe 'when EC2 cannot be queried'
    It 'backs off without creating a volume'
      aws() { printf '%s\n' "$*" >> "$CALLS"; return 1; }
      attempt_grow 95 2>/dev/null
      NOW=1009
      When call attempt_grow 95
      The status should equal 1
      The value "$(create_count)" should equal 0
      The value "$(aws_call_count)" should equal 1
    End

    It 'retries the query once the backoff has elapsed'
      aws() { printf '%s\n' "$*" >> "$CALLS"; return 1; }
      attempt_grow 95 2>/dev/null
      NOW=1010
      When call attempt_grow 95
      The stderr should include 'could not query EC2'
      The value "$(aws_call_count)" should equal 2
    End
  End

  Describe 'when a failed attempt outlasts the backoff'
    It 'times the backoff from when the attempt ended'
      grow_filesystem() { NOW=$(( NOW + 60 )); return 1; }
      attempt_grow 95 2>/dev/null
      NOW=1069
      When call attempt_grow 95
      The status should equal 1
      The value "$(create_count)" should equal 1
    End
  End

  Describe 'when creating the volume fails'
    It 'fails when create-ebs-volume exits 1 even if it printed a device'
      create_exits 1
      When call add_space 1 100
      The status should equal 1
      The stderr should include 'status 1'
    End

    It 'does not advance the device count'
      create_fails
      When call attempt_grow 95
      The stderr should include 'growing failed'
      The value "$NUM_DEVICES" should equal 1
    End

    It 'does not advance the device count when extending the filesystem fails'
      GROW_RC=1
      When call attempt_grow 95
      The stderr should include 'growing failed'
      The value "$NUM_DEVICES" should equal 1
    End

    It 'does not retry before the backoff has elapsed'
      create_fails
      attempt_grow 95 2>/dev/null
      NOW=1009
      When call attempt_grow 95
      The status should equal 1
      The value "$(create_count)" should equal 1
    End

    It 'retries once the first backoff of 10 seconds has elapsed'
      create_fails
      attempt_grow 95 2>/dev/null
      NOW=1010
      When call attempt_grow 95
      The stderr should include 'growing failed'
      The value "$(create_count)" should equal 2
    End

    It 'doubles the wait after each consecutive failure'
      create_fails
      attempt_grow 95 2>/dev/null
      NOW=1010
      attempt_grow 95 2>/dev/null
      NOW=1029
      When call attempt_grow 95
      The status should equal 1
      The value "$(create_count)" should equal 2
    End

    It 'caps the wait at 5 minutes'
      create_fails
      fail_repeatedly() {
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
          NOW=$(( NOW + 1000 ))
          attempt_grow 95 2>/dev/null
        done
        NOW=$(( NOW + 299 ))
        attempt_grow 95 2>/dev/null
        echo "before: $(create_count)"
        NOW=$(( NOW + 1 ))
        attempt_grow 95 2>/dev/null
        echo "after: $(create_count)"
      }
      When call fail_repeatedly
      The output should equal "$(printf 'before: 10\nafter: 11')"
    End

    It 'starts over at 10 seconds after a growth limit'
      create_fails
      attempt_grow 95 2>/dev/null
      NOW=1010; attempt_grow 95 2>/dev/null
      set_volumes 2 100
      NOW=1030; attempt_grow 95
      set_volumes 1 100
      NOW=1330; attempt_grow 95 2>/dev/null
      NOW=1340
      When call attempt_grow 95
      The stderr should include 'growing failed'
      The value "$(create_count)" should equal 4
    End

    It 'starts over at 10 seconds after a success'
      create_fails
      attempt_grow 95 2>/dev/null
      NOW=1010
      create_succeeds
      attempt_grow 95
      create_fails
      NOW=1011
      attempt_grow 95 2>/dev/null
      NOW=1020
      When call attempt_grow 95
      The status should equal 1
      The value "$(create_count)" should equal 3
    End
  End
End
