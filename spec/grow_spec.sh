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
  create_succeeds() { echo /dev/nvme1n1 > "$CREATE_OUTPUT"; }
  create_fails() { : > "$CREATE_OUTPUT"; }
  create_count() { wc -l < "$CREATES" | tr -d ' '; }
  aws_call_count() { wc -l < "$CALLS" | tr -d ' '; }

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
