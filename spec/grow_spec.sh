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
    NUM_DEVICES=0; THRESHOLD=50; NOW=1000; MIN_FREE_SPACE=0
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
    _nvme_candidates() { :; }
    lsblk() { :; }
    pvs() { :; }
    timeout() { shift 3; "$@"; }
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
      '{Volumes: [range($n) | {VolumeId: "vol-0\(.)", Size: $size, State: "in-use",
        Tags: [{Key: "amazon-ebs-autoscale-creation-time", Value: "t"}],
        Attachments: [{InstanceId: $iid, Device: "/dev/sd\([102 + .] | implode)", State: "attached", DeleteOnTermination: true}]}]}')
  }
  # Points run_daemon at a scratch mount and a fresh log, and makes it stop after one tick.
  loop_setup() {
    MOUNTPOINT="$SHELLSPEC_TMPBASE"; LOG_INTERVAL=1; DETECTION_INTERVAL=2
    EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.loop-log"
    : > "$EBS_AUTOSCALE_LOG_FILE"
    sleep() { exit 0; }
  }
  create_succeeds() { echo /dev/nvme1n1 > "$CREATE_OUTPUT"; }
  create_fails() { : > "$CREATE_OUTPUT"; }
  # create_exits STATUS: create-ebs-volume prints CREATE_OUTPUT, then exits STATUS.
  # shellcheck disable=SC2016
  create_exits() { printf '#!/bin/sh\necho create >> "$CREATES"\ncat "$CREATE_OUTPUT"\nexit %s\n' "$1" > "$CREATE_VOLUME"; }
  create_at_limit() { create_fails; create_exits 3; }
  create_errors() { create_fails; create_exits 1; }
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
          "  *describe-volumes*) jq -nc '{Volumes: [{VolumeId: \"vol-0a\", Size: 7900, State: \"available\", Attachments: []}]}' ;;" \
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

    It 'made one describe-volumes call'
      When call attempt_grow 95
      The status should be success
      The value "$(create_count)" should equal 1
      The value "$(aws_call_count)" should equal 1
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

  It 'logs the utilization and threshold when low on disk'
    EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.log"
    : > "$EBS_AUTOSCALE_LOG_FILE"
    When call attempt_grow 95 $(( 50 * BYTES_PER_GB ))
    The status should be success
    The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'low disk (util=95% threshold=50%)'
    The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'min_free='
  End

  Describe 'in free-space mode'
    free_space_mode() { MIN_FREE_SPACE=100; MAX_EBS_VOLUME_COUNT=16; }
    Before 'free_space_mode'

    It 'grows when free space is under the floor at low utilization'
      When call attempt_grow 10 $(( 50 * BYTES_PER_GB ))
      The status should be success
      The value "$(create_count)" should equal 1
    End

    It 'does not grow when free space is over the floor at 95% utilization'
      When call attempt_grow 95 $(( 150 * BYTES_PER_GB ))
      The status should be success
      The value "$(create_count)" should equal 0
    End

    It 'does not grow when free space is exactly the floor'
      When call attempt_grow 95 $(( 100 * BYTES_PER_GB ))
      The status should be success
      The value "$(create_count)" should equal 0
    End

    It 'grows when free space is one byte under the floor'
      When call attempt_grow 10 $(( 100 * BYTES_PER_GB - 1 ))
      The status should be success
      The value "$(create_count)" should equal 1
    End

    It 'does not apply the raised threshold of a high device count'
      set_volumes 5 100
      When call attempt_grow 60 $(( 50 * BYTES_PER_GB ))
      The status should be success
      The value "$(create_count)" should equal 1
    End

    It 'logs the free space rather than the utilization'
      EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.log"
      : > "$EBS_AUTOSCALE_LOG_FILE"
      When call attempt_grow 10 $(( 50 * BYTES_PER_GB ))
      The status should be success
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'low disk (free=50GB min_free=100GB)'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'util='
    End

    Describe 'sizing the next volume'
      record_create_args() {
        MAX_LOGICAL_VOLUME_SIZE=8000
        # shellcheck disable=SC2016
        printf '#!/bin/sh\necho "$*" >> "$CREATES"\ncat "$CREATE_OUTPUT"\n' > "$CREATE_VOLUME"
      }
      Before 'record_create_args'
      requested_sizes() { sed -n 's/.*--size \([0-9]*\).*/\1/p' "$CREATES"; }

      It 'covers the shortfall padded by 3% in one grow rather than the ladder size'
        MIN_FREE_SPACE=1000; set_volumes 1 300
        When call attempt_grow 1 $(( 300 * BYTES_PER_GB ))
        The status should be success
        The result of function requested_sizes should equal 721
      End

      It 'uses the ladder size when the shortfall is smaller'
        MIN_FREE_SPACE=1000
        When call attempt_grow 10 $(( 950 * BYTES_PER_GB ))
        The status should be success
        The result of function requested_sizes should equal 150
      End

      It 'caps the shortfall at the max volume size'
        MIN_FREE_SPACE=5000
        When call attempt_grow 1 $(( 300 * BYTES_PER_GB ))
        The status should be success
        The result of function requested_sizes should equal 1500
      End

      It 'caps the shortfall at the room left under the max total size'
        MIN_FREE_SPACE=1000; set_volumes 1 7500
        When call attempt_grow 1 $(( 300 * BYTES_PER_GB ))
        The status should be success
        The result of function requested_sizes should equal 500
      End

      It 'keeps the ladder size in percentage mode'
        MIN_FREE_SPACE=0
        When call attempt_grow 95 $(( 1 * BYTES_PER_GB ))
        The status should be success
        The result of function requested_sizes should equal 150
      End
    End

    It 'backs off after a failed grow like the percentage mode'
      create_errors
      attempt_grow 10 $(( 50 * BYTES_PER_GB )) 2>/dev/null
      NOW=1009
      When call attempt_grow 10 $(( 50 * BYTES_PER_GB ))
      The status should equal 1
      The value "$(create_count)" should equal 1
    End

    Describe 'the main loop'
      Before 'loop_setup'

      It 'grows when free space is under the floor at low utilization'
        read_fs_stats() { echo "$(( 1000 * BYTES_PER_GB )) $(( 950 * BYTES_PER_GB )) $(( 50 * BYTES_PER_GB )) 10"; }
        When run run_daemon
        The status should be success
        The value "$(create_count)" should equal 1
      End

      It 'does not grow when free space is over the floor at 95% utilization'
        read_fs_stats() { echo "$(( 1000 * BYTES_PER_GB )) $(( 850 * BYTES_PER_GB )) $(( 150 * BYTES_PER_GB )) 95"; }
        When run run_daemon
        The status should be success
        The value "$(create_count)" should equal 0
      End

      It 'reconciles at startup over the floor without growing'
        read_fs_stats() { echo "$(( 1000 * BYTES_PER_GB )) $(( 850 * BYTES_PER_GB )) $(( 150 * BYTES_PER_GB )) 95"; }
        When run run_daemon
        The status should be success
        The value "$(aws_call_count)" should equal 2
        The value "$(create_count)" should equal 0
      End
    End
  End

  Describe 'the periodic log line'
    Before 'loop_setup'

    It 'shows the free-space trigger in free-space mode'
      MIN_FREE_SPACE=100
      read_fs_stats() { echo "$(( 1000 * BYTES_PER_GB )) $(( 850 * BYTES_PER_GB )) $(( 150 * BYTES_PER_GB )) 95"; }
      When run run_daemon
      The status should be success
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'free=150GB min_free=100GB'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'threshold='
    End

    It 'shows the utilization threshold in percentage mode'
      read_fs_stats() { echo '100 10 90 10'; }
      When run run_daemon
      The status should be success
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'util=10% threshold=50%'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'min_free='
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

  Describe 'when an attached autoscaled volume lacks DeleteOnTermination'
    dot_setup() {
      EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.dot-log"
      : > "$EBS_AUTOSCALE_LOG_FILE"
    }
    Before 'dot_setup'

    # clear_dot INDEX [UPDATE]: applies UPDATE (default: DeleteOnTermination false) to volume INDEX's attachment.
    clear_dot() {
      VOLUMES_JSON=$(printf '%s' "$VOLUMES_JSON" | jq -c --argjson i "$1" ".Volumes[\$i].Attachments[0] |= (${2:-.DeleteOnTermination = false})")
    }
    modify_calls() { grep -c modify-instance-attribute "$CALLS" || :; }

    It 'enables it with one modify call by BDM name and volume ID'
      set_volumes 2 100
      clear_dot 1
      When call attempt_grow 10
      The status should be success
      The result of function modify_calls should equal 1
      The contents of file "$CALLS" should include 'DeviceName=/dev/sdg,Ebs={DeleteOnTermination=true,VolumeId=vol-01}'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'enabled DeleteOnTermination on vol-01 (/dev/sdg)'
    End

    It 'treats a missing DeleteOnTermination as false'
      clear_dot 0 'del(.DeleteOnTermination)'
      When call attempt_grow 10
      The result of function modify_calls should equal 1
    End

    It 'makes no modify call when every volume has it'
      set_volumes 2 100
      When call attempt_grow 10
      The status should be success
      The result of function modify_calls should equal 0
    End

    It 'stops at an authorization error and still grows'
      MAX_EBS_VOLUME_COUNT=16
      set_volumes 2 100
      clear_dot 0; clear_dot 1
      aws() {
        printf '%s\n' "$*" >> "$CALLS"
        case "$*" in
          *modify-instance-attribute*)
            echo 'An error occurred (UnauthorizedOperation) when calling the ModifyInstanceAttribute operation: denied' >&2
            return 254
            ;;
        esac
        printf '%s' "$VOLUMES_JSON"
      }
      When call attempt_grow 95
      The status should be success
      The result of function modify_calls should equal 1
      The value "$(create_count)" should equal 1
      The stderr should include 'ec2:ModifyInstanceAttribute'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'finished extending'
    End

    It 'repairs a volume left without it at the startup reconcile'
      loop_setup
      clear_dot 0
      read_fs_stats() { echo '100 10 90 10'; }
      When run run_daemon
      The status should be success
      The result of function modify_calls should equal 1
      The value "$(create_count)" should equal 0
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'enabled DeleteOnTermination on vol-00 (/dev/sdf)'
    End
  End

  Describe 'when an autoscaled volume is attached outside the volume group'
    # Fixtures mirror output captured on AL2023 with lvm2 2.03.16, with made-up IDs.
    use_stray_fixtures() {
      INSTANCE_ID='i-0e1f2a3b4c5d6e7f8'; LVM_VG=autoscale_vg; LVM_LV=autoscale_lv
      MAX_EBS_VOLUME_COUNT=16
      VOLUMES_JSON=$(fixture describe-volumes.json)
      LSBLK=$(fixture lsblk-name-serial.txt)
      PVS=$(fixture pvs-pv-vg.txt)
      ALIASES=$(fixture udev-aliases.txt)
      EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.log"
      GROWS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.grows"
      : > "$EBS_AUTOSCALE_LOG_FILE"; : > "$GROWS"
      echo /dev/nvme3n1 > "$CREATE_OUTPUT"
      grow_filesystem() { echo "$1" >> "$GROWS"; return "$GROW_RC"; }
      _nvme_candidates() { printf '%s\n' "$LSBLK" | awk '{print "/dev/" $1}'; }
      # Mimics lsblk -dno NAME,SERIAL for every disk, -dno SERIAL DEV for one, and
      # -nro NAME,FSTYPE,PTTYPE DEV from the DISKS rows for DEV and its partitions.
      DISKS=''
      lsblk() {
        case "$*" in
          *NAME,SERIAL*) printf '%s\n' "$LSBLK" ;;
          *FSTYPE*)
            for dev; do :; done
            printf '%s\n' "$DISKS" | awk -v n="${dev#/dev/}" \
              '$1 == n || index($1, n "p") == 1 { print; found = 1 } END { if (!found) print n "  " }'
            ;;
          *) for dev; do :; done; printf '%s\n' "$LSBLK" | awk -v n="${dev#/dev/}" '$1 == n {print $2}' ;;
        esac
      }
      # ebsnvme-id knows the EBS devices in EBSNVME_IDS and rejects every other device.
      EBSNVME="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.ebsnvme-id"
      EBSNVME_CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.ebsnvme-calls"
      EBSNVME_IDS=$(printf '%s\n' "$LSBLK" | awk '$2 ~ /^vol/ { print $1, "vol-" substr($2, 4) }')
      : > "$EBSNVME_CALLS"
      export EBSNVME_CALLS EBSNVME_IDS
      # shellcheck disable=SC2016
      printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$EBSNVME_CALLS"' 'for d; do :; done' \
        'id=$(printf "%s\n" "$EBSNVME_IDS" | awk -v n="${d#/dev/}" "\$1 == n { print \$2 }")' \
        '[ -n "$id" ] || { echo "[ERROR] Not an EBS device: $d" >&2; exit 1; }' \
        'echo "Volume ID: $id"' > "$EBSNVME"
      chmod +x "$EBSNVME"
      ebsnvme_calls() { wc -l < "$EBSNVME_CALLS" | tr -d ' '; }
      pvs() { printf '%s\n' "$PVS"; }
      # Resolves the /dev/sdX aliases that pvs reports to their NVMe devices.
      readlink() { printf '%s\n' "$ALIASES" | awk -v p="$2" '$1 == p {print $2; found = 1} END {if (!found) print p}'; }
    }
    Before 'use_stray_fixtures'

    It 'folds it into the volume group instead of creating a volume'
      When call attempt_grow 95
      The status should be success
      The contents of file "$GROWS" should equal /dev/nvme2n1
      The value "$(create_count)" should equal 0
    End

    It 'logs the fold'
      When call attempt_grow 95
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'folding stray volume vol-0b2c3d4e5f6071829 (/dev/nvme2n1) into autoscale_vg'
    End

    It 'counts the folded volume as attached'
      When call attempt_grow 95
      The value "$NUM_DEVICES" should equal 2
    End

    It 'folds it and counts volumes from one describe-volumes call'
      When call attempt_grow 95
      The contents of file "$GROWS" should equal /dev/nvme2n1
      The value "$(grep -c describe-volumes "$CALLS")" should equal 1
    End

    It 'enables DeleteOnTermination on it as well as folding it'
      When call attempt_grow 95
      The contents of file "$GROWS" should equal /dev/nvme2n1
      The contents of file "$CALLS" should include 'DeviceName=/dev/sdg,Ebs={DeleteOnTermination=true,VolumeId=vol-0b2c3d4e5f6071829}'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'enabled DeleteOnTermination on vol-0b2c3d4e5f6071829 (/dev/sdg)'
    End

    It 'folds it even when it fills the attached volume limit'
      MAX_EBS_VOLUME_COUNT=2
      When call attempt_grow 95
      The contents of file "$GROWS" should equal /dev/nvme2n1
    End

    It 'folds it even when usage is under the threshold'
      When call attempt_grow 10
      The contents of file "$GROWS" should equal /dev/nvme2n1
    End

    It 'folds it under the free-space floor without also creating a volume'
      MIN_FREE_SPACE=100
      When call attempt_grow 10 $(( 50 * BYTES_PER_GB ))
      The status should be success
      The contents of file "$GROWS" should equal /dev/nvme2n1
      The value "$(create_count)" should equal 0
    End

    It 'folds a physical volume that is in no volume group'
      PVS=$(printf '  /dev/sdf   autoscale_vg\n  /dev/sdg               ')
      DISKS='nvme2n1 LVM2_member '
      When call attempt_grow 95
      The contents of file "$GROWS" should equal /dev/nvme2n1
    End

    Describe 'that is not blank'
      Parameters
        'with a filesystem' 'nvme2n1 ext4 ' '  /dev/sdf   autoscale_vg' 'it has a filesystem or partitions'
        'with partitions' "$(printf 'nvme2n1  gpt\nnvme2n1p1 xfs ')" '  /dev/sdf   autoscale_vg' 'it has a filesystem or partitions'
        'in another volume group' 'nvme2n1 LVM2_member ' "$(printf '  /dev/sdf   autoscale_vg\n  /dev/sdg   data_vg')" 'it is in volume group data_vg'
      End

      It "skips one $1 with a warning and creates a volume"
        DISKS=$2
        PVS=$3
        When call attempt_grow 95
        The status should be success
        The stderr should include "not folding stray volume vol-0b2c3d4e5f6071829 (/dev/nvme2n1): $4"
        The contents of file "$GROWS" should equal /dev/nvme3n1
        The value "$(create_count)" should equal 1
      End
    End

    It 'creates a volume once every attached volume is in the volume group'
      PVS=$(fixture pvs-pv-vg-folded.txt)
      When call attempt_grow 95
      The value "$(create_count)" should equal 1
      The contents of file "$GROWS" should equal /dev/nvme3n1
    End

    It 'does not fold a device whose serial is not an attached volume of this instance'
      PVS=$(fixture pvs-pv-vg-folded.txt)
      LSBLK=$(printf '%s\nnvme3n1 vol0c3d4e5f607182930' "$LSBLK")
      echo /dev/nvme4n1 > "$CREATE_OUTPUT"
      When call attempt_grow 95
      The contents of file "$GROWS" should equal /dev/nvme4n1
    End

    It 'does not fold a volume that is detaching'
      VOLUMES_JSON=$(fixture describe-volumes.json | jq -c '.Volumes[1].Attachments[0].State = "detaching"')
      When call attempt_grow 95
      The contents of file "$GROWS" should equal /dev/nvme3n1
    End

    It 'does not create a volume when the fold fails'
      GROW_RC=1
      When call attempt_grow 95
      The status should be success
      The stderr should include 'growing failed'
      The value "$(create_count)" should equal 0
    End

    It 'does not create a volume when the volume group cannot be listed'
      pvs() { echo '  lvm error' >&2; return 5; }
      When call attempt_grow 95
      The stderr should include 'growing failed'
      The value "$(create_count)" should equal 0
    End

    It 'logs why pvs failed'
      pvs() { echo '  Volume group "autoscale_vg" lock timed out' >&2; return 5; }
      When call attempt_grow 95
      The stderr should include 'pvs failed (status 5)'
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'lock timed out'
    End

    It 'gives up on pvs after the LVM timeout'
      TIMEOUTS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.timeouts"
      : > "$TIMEOUTS"
      timeout() { echo "$*" >> "$TIMEOUTS"; return 124; }
      When call attempt_grow 95
      The stderr should include 'pvs failed (status 124)'
      The contents of file "$TIMEOUTS" should equal '-k 6 60 pvs --noheadings -o pv_name,vg_name'
      The value "$(create_count)" should equal 0
    End

    Describe 'alongside instance-store disks'
      It 'matches devices by serial without running ebsnvme-id or logging per volume'
        LSBLK=$(printf '%s\nnvme4n1 AWS0XYZ\nnvme5n1 AWS1XYZ\nnvme6n1 AWS2XYZ\nnvme7n1 AWS3XYZ' "$LSBLK")
        When call attempt_grow 95
        The contents of file "$GROWS" should equal /dev/nvme2n1
        The value "$(ebsnvme_calls)" should equal 0
        The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'Not an EBS device'
      End

      It 'runs ebsnvme-id once for each device that has no serial'
        LSBLK=$(printf 'nvme0n1 vol0f0e1d2c3b4a59687\nnvme1n1 vol0a1b2c3d4e5f60718\nnvme2n1\nnvme4n1\nnvme5n1\nnvme6n1')
        EBSNVME_IDS='nvme2n1 vol-0b2c3d4e5f6071829'
        When call attempt_grow 95
        The contents of file "$GROWS" should equal /dev/nvme2n1
        The value "$(ebsnvme_calls)" should equal 4
        The contents of file "$EBS_AUTOSCALE_LOG_FILE" should not include 'Not an EBS device'
      End
    End

    Describe 'when the daemon starts'
      run_daemon_at_10_percent() {
        MOUNTPOINT="$SHELLSPEC_TMPBASE"; LOG_INTERVAL=1; DETECTION_INTERVAL=2
        read_fs_stats() { echo '100 10 90 10'; }
        run_daemon
      }

      It 'folds it even when usage is under the threshold'
        sleep() { exit 0; }
        When run run_daemon_at_10_percent
        The status should be success
        The contents of file "$GROWS" should equal /dev/nvme2n1
      End

      It 'folds it without creating a volume when free space is over the floor'
        MIN_FREE_SPACE=100
        MOUNTPOINT="$SHELLSPEC_TMPBASE"; LOG_INTERVAL=1; DETECTION_INTERVAL=2
        read_fs_stats() { echo "$(( 1000 * BYTES_PER_GB )) $(( 850 * BYTES_PER_GB )) $(( 150 * BYTES_PER_GB )) 85"; }
        sleep() { exit 0; }
        When run run_daemon
        The status should be success
        The contents of file "$GROWS" should equal /dev/nvme2n1
        The value "$(create_count)" should equal 0
      End

      It 'retries a failed fold after the backoff even when usage is under the threshold'
        grow_filesystem() { echo "$1" >> "$GROWS"; [ "$(wc -l < "$GROWS")" -gt 1 ]; }
        sleep() { NOW=$(( NOW + 10 )); [ "$NOW" -lt 1020 ] || exit 0; }
        When run run_daemon_at_10_percent
        The status should be success
        The stderr should include 'growing failed'
        The contents of file "$GROWS" should equal "$(printf '/dev/nvme2n1\n/dev/nvme2n1')"
      End
    End
  End

  Describe 'lvresize_full'
    # LVM exits 5 both when the LV is already full and when the LV or VG is missing.
    use_lvm_stubs() {
      LVM_VG=autoscale_vg
      VGS=$(fixture vgs-vg-free-count-0.txt)
      vgs() { printf '%s\n' "$VGS"; }
    }
    Before 'use_lvm_stubs'

    It 'treats exit 5 as already at size when the volume group has no free extents'
      lvresize() { echo '  New size (2559 extents) matches existing size (2559 extents).' >&2; return 5; }
      When call lvresize_full /dev/mapper/autoscale_vg-autoscale_lv
      The status should be success
      The stderr should include 'matches existing size'
    End

    It 'fails on exit 5 while the volume group has free extents'
      VGS=$(fixture vgs-vg-free-count-2559.txt)
      lvresize() { echo '  Logical volume nope not found in volume group autoscale_vg.' >&2; return 5; }
      When call lvresize_full /dev/mapper/autoscale_vg-nope
      The status should be failure
      The stderr should include 'lvresize failed (status 5), attempt 3/3'
    End

    It 'fails on exit 5 when the free extents cannot be read'
      vgs() { echo '  Volume group "autoscale_vg" not found' >&2; return 5; }
      lvresize() { echo '  Volume group "autoscale_vg" not found' >&2; return 5; }
      When call lvresize_full /dev/mapper/autoscale_vg-autoscale_lv
      The status should be failure
      The stderr should include 'vgs failed (status 5)'
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

    It 'keeps doubling the wait when usage dips under the threshold between failures'
      create_errors
      attempt_grow 95 2>/dev/null
      NOW=1010; attempt_grow 10
      When call attempt_grow 95
      The stderr should include 'growing failed; next attempt in 20s'
    End

    It 'doubles the wait to 5 minutes while usage swings across the threshold'
      create_errors
      MOUNTPOINT="$SHELLSPEC_TMPBASE"; LOG_INTERVAL=1000000; DETECTION_INTERVAL=2
      EBS_AUTOSCALE_LOG_FILE="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.swing.log"
      : > "$EBS_AUTOSCALE_LOG_FILE"
      # Usage is 60% and 40% in alternating minutes.
      read_fs_stats() {
        if [ $(( (NOW - 1000) / 60 % 2 )) -eq 0 ]; then echo '100 60 40 60'; else echo '100 40 60 40'; fi
      }
      sleep() { NOW=$(( NOW + DETECTION_INTERVAL )); [ "$NOW" -lt 1800 ] || exit 0; }
      delays() {
        (run_daemon 2>/dev/null)
        grep -o 'next attempt in [0-9]*s' "$EBS_AUTOSCALE_LOG_FILE" | awk '{ print $4 }' | head -6 | tr '\n' ' '
      }
      When call delays
      The output should equal '10s 20s 40s 80s 160s 300s '
    End
  End
End
