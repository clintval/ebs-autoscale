# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/create-ebs-volume volume creation'
  Include bin/create-ebs-volume

  Describe 'instance_tag_specifications'
    # Building the payload with jq must survive tag values containing spaces,
    # commas, colons, and quotes, and must drop reserved aws: tags.
    It 'emits valid JSON for tag values with spaces, commas, colons, and quotes'
      AWS_REGION=us-west-2
      aws() { echo '{"Tags":[{"Key":"Name","Value":"a, b: c \"d\""},{"Key":"aws:cloudformation:stack-name","Value":"x"}]}'; }
      check() { instance_tag_specifications i-0123 2026-01-01T00:00:00Z | jq empty; }
      When call check
      The status should be success
    End

    It 'includes the source-instance tag and excludes aws: tags'
      AWS_REGION=us-west-2
      aws() { echo '{"Tags":[{"Key":"aws:cloudformation:stack-name","Value":"x"}]}'; }
      When call instance_tag_specifications i-0123 2026-01-01T00:00:00Z
      The output should include '"source-instance"'
      The output should not include 'aws:cloudformation'
    End
  End

  Describe 'create_and_attach_volume'
    setup() {
      SIZE=100; TYPE=gp3; IOPS=3000; THROUGHPUT=125; ENCRYPTED=1
      MAX_LOGICAL_VOLUME_SIZE=8000; MAX_ATTACHED_VOLUMES=16; MAX_CREATED_VOLUMES=16
      INSTANCE_ID=i-0123; AWS_AZ=us-west-2a; AWS_REGION=us-west-2
      OWNED_VOLUMES='{"Volumes":[]}'
      CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.aws-calls"
      : > "$CALLS"
      export CALLS
      # Deterministic stubs for the device layer.
      get_next_logical_device() { printf '/dev/sdf'; }
      resolve_nvme_device() { printf '/dev/nvme1n1'; }
      sleep() { :; }
      # Record every aws invocation and return canned responses.
      aws() {
        printf '%s\n' "$*" >> "$CALLS"
        case "$*" in
          *describe-tags*)               echo '{"Tags":[]}' ;;
          *describe-volumes*--volume-ids*) echo "${VOLUME_STATE:-available}" ;;
          *describe-volumes*)            echo "$OWNED_VOLUMES" ;;
          *create-volume*)               echo '{"VolumeId":"vol-0abc"}' ;;
          *attach-volume*)               return "${ATTACH_RC:-0}" ;;
          *modify-instance-attribute*)   return "${MODIFY_RC:-0}" ;;
          *delete-volume*)
            [ "${DELETE_RC:-0}" -eq 0 ] || echo 'An error occurred (IncorrectState)' >&2
            return "${DELETE_RC:-0}"
            ;;
          *)                             return 0 ;;
        esac
      }
    }
    Before 'setup'

    modify_calls() { grep -c modify-instance-attribute "$CALLS"; }

    # Happy path returns the real NVMe device, and DeleteOnTermination must
    # reference the BDM name, not the NVMe path.
    It 'prints the real NVMe device and enables DeleteOnTermination by BDM name'
      When run create_and_attach_volume
      The status should be success
      The output should equal /dev/nvme1n1
      The contents of file "$CALLS" should include 'DeviceName=/dev/sdf'
    End

    It 'exits 3 without creating a volume that would take the total created size past the max'
      OWNED_VOLUMES='{"Volumes":[{"Size":7900}]}'
      SIZE=1500
      When run create_and_attach_volume
      The status should equal 3
      The stderr should include 'would exceed the maximum total EBS volume size'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    It 'exits 3 without creating a first volume larger than the max total size'
      SIZE=8001
      When run create_and_attach_volume
      The status should equal 3
      The stderr should include 'would exceed the maximum total EBS volume size'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    It 'creates a volume that brings the total created size exactly to the max'
      OWNED_VOLUMES='{"Volumes":[{"Size":6500}]}'
      SIZE=1500
      When run create_and_attach_volume
      The status should be success
      The output should equal /dev/nvme1n1
    End

    # A failed DeleteOnTermination is logged loudly but must not abort the attach.
    It 'logs an ERR but still returns the device when DeleteOnTermination never succeeds'
      MODIFY_RC=1
      When run create_and_attach_volume
      The status should be success
      The output should equal /dev/nvme1n1
      The stderr should include 'DeleteOnTermination NOT enabled'
      The result of function modify_calls should equal 5
      The contents of file "$CALLS" should not include 'delete-volume'
    End

    # If the volume never becomes available it must be deleted, not leaked.
    It 'deletes the volume when it enters the error state'
      VOLUME_STATE=error
      When run create_and_attach_volume
      The status should equal 1
      The contents of file "$CALLS" should include 'delete-volume'
      The stderr should include 'did not become available'
    End

    It 'deletes the volume when it is still not available at the timeout'
      VOLUME_STATE=creating
      EBS_AUTOSCALE_VOLUME_AVAILABLE_TIMEOUT=0
      When run create_and_attach_volume
      The status should equal 1
      The stderr should include 'timed out'
      The contents of file "$CALLS" should include 'delete-volume'
    End

    It 'reports a possible leak when a timed-out volume cannot be deleted'
      VOLUME_STATE=creating
      EBS_AUTOSCALE_VOLUME_AVAILABLE_TIMEOUT=0
      DELETE_RC=1
      When run create_and_attach_volume
      The status should equal 1
      The stderr should include 'could not be deleted'
      The stderr should include 'IncorrectState'
      The stderr should not include 'deleted it'
    End

    # A reached limit exits 3 so callers can tell it from a failure.
    It 'exits 3 without creating a volume at the total created size limit'
      MAX_LOGICAL_VOLUME_SIZE=0
      When run create_and_attach_volume
      The status should equal 3
      The stderr should include 'maximum total EBS volume size'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    It 'exits 3 without creating a volume at the created volume limit'
      MAX_CREATED_VOLUMES=0
      When run create_and_attach_volume
      The status should equal 3
      The stderr should include 'maximum number of created volumes'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    It 'exits 3 without creating a volume at the attached volume limit'
      MAX_ATTACHED_VOLUMES=0
      When run create_and_attach_volume
      The status should equal 3
      The stderr should include 'maximum number of attached volumes'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    It 'exits 3 without creating a volume when no device names are free'
      get_next_logical_device() { return 1; }
      When run create_and_attach_volume
      The status should equal 3
      The stderr should include 'no device names available'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    Describe 'when describe-volumes'
      Parameters
        fails 254
        'returns nothing' 0
      End

      It "$1 exits 1 without creating a volume"
        DESCRIBE_RC=$2
        aws() {
          printf '%s\n' "$*" >> "$CALLS"
          case "$*" in
            *describe-volumes*--filters*) return "$DESCRIBE_RC" ;;
            *describe-volumes*)           echo available ;;
            *create-volume*)              echo '{"VolumeId":"vol-0abc"}' ;;
          esac
        }
        When run create_and_attach_volume
        The status should equal 1
        The stderr should include 'could not query EC2'
        The contents of file "$CALLS" should not include 'create-volume'
      End
    End

    # A failed attach must also delete the just-created volume.
    It 'deletes the volume when the attach fails'
      ATTACH_RC=1
      When run create_and_attach_volume
      The status should equal 1
      The stdout should equal ""
      The stderr should include 'could not attach'
      The contents of file "$CALLS" should include 'delete-volume'
    End
  End

  Describe 'wait_for_volume_available'
    setup() {
      AWS_REGION=us-west-2
      POLLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.polls"
      SLEEPS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.sleeps"
      : > "$POLLS"; : > "$SLEEPS"
      export POLLS SLEEPS
      sleep() { printf '%s\n' "$1" >> "$SLEEPS"; }
      # Reports "creating" until the Nth poll, then the configured final state.
      aws() {
        echo poll >> "$POLLS"
        if [ "$(wc -l < "$POLLS")" -ge "${READY_ON_POLL:-1}" ]; then
          echo "${FINAL_STATE:-available}"
        else
          echo creating
        fi
      }
    }
    Before 'setup'

    It 'returns success once the volume becomes available'
      READY_ON_POLL=3
      When call wait_for_volume_available vol-0abc
      The status should be success
      The contents of file "$POLLS" should eq "$(printf 'poll\npoll\npoll')"
    End

    It 'polls only the requested volume'
      aws() { echo "$*" >> "$POLLS"; echo available; }
      When call wait_for_volume_available vol-0abc
      The contents of file "$POLLS" should include '--volume-ids vol-0abc'
    End

    It 'does not sleep when the volume is already available'
      When call wait_for_volume_available vol-0abc
      The contents of file "$SLEEPS" should equal ""
    End

    It 'fails immediately when the volume enters the error state'
      READY_ON_POLL=2
      FINAL_STATE=error
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'state error'
      The contents of file "$POLLS" should eq "$(printf 'poll\npoll')"
    End

    It 'fails immediately when the volume is being deleted'
      FINAL_STATE=deleting
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'state deleting'
    End

    It 'fails immediately when the volume has been deleted'
      FINAL_STATE=deleted
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'state deleted'
    End

    It 'fails at once when describe-volumes errors'
      aws() {
        echo poll >> "$POLLS"
        echo 'An error occurred (UnauthorizedOperation)' >&2
        return 254
      }
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'could not describe volume vol-0abc'
      The contents of file "$POLLS" should equal poll
      The contents of file "$EBS_AUTOSCALE_LOG_FILE" should include 'UnauthorizedOperation'
    End

    It 'keeps polling when describe-volumes returns nothing'
      aws() {
        echo poll >> "$POLLS"
        if [ "$(wc -l < "$POLLS")" -ge 3 ]; then echo available; fi
      }
      When call wait_for_volume_available vol-0abc
      The status should be success
      The contents of file "$POLLS" should eq "$(printf 'poll\npoll\npoll')"
    End

    It 'stops polling soon after the timeout rather than continuing forever'
      READY_ON_POLL=1000
      EBS_AUTOSCALE_VOLUME_AVAILABLE_TIMEOUT=20
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'timed out'
      The value "$(awk 'END { print (NR < 15) ? "bounded" : "unbounded" }' "$POLLS")" should equal bounded
    End

    It 'waits up to 600 seconds by default'
      READY_ON_POLL=100000
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'timed out'
      The value "$(awk '{ t += $1 } END { print (t >= 600 && t < 606.25) ? "600 s" : t }' "$SLEEPS")" should equal "600 s"
    End

    It 'polls once more after the last sleep before timing out'
      READY_ON_POLL=1000
      EBS_AUTOSCALE_VOLUME_AVAILABLE_TIMEOUT=20
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'timed out'
      The value "$(( $(wc -l < "$POLLS") - $(wc -l < "$SLEEPS") ))" should equal 1
    End

    It 'polls once before timing out when the timeout is zero'
      READY_ON_POLL=1000
      EBS_AUTOSCALE_VOLUME_AVAILABLE_TIMEOUT=0
      When call wait_for_volume_available vol-0abc
      The status should equal 1
      The stderr should include 'timed out'
      The contents of file "$POLLS" should equal poll
      The contents of file "$SLEEPS" should equal ""
    End

    It 'starts polling at about a second'
      READY_ON_POLL=2
      When call wait_for_volume_available vol-0abc
      The contents of file "$SLEEPS" should match pattern '0.[789]*|1.[0-2]*'
    End

    It 'lengthens the delay between polls as it waits'
      READY_ON_POLL=6
      When call wait_for_volume_available vol-0abc
      # The 5th delay has a 5 s base, so jitter keeps it within [3.75, 6.25] s.
      The value "$(sed -n 5p "$SLEEPS" | awk '{print ($1 >= 3.75 && $1 <= 6.25) ? "backed off" : "off"}')" should equal "backed off"
    End

    It 'spreads sleeps around the 5 second cap rather than pinning them to it'
      READY_ON_POLL=40
      When call wait_for_volume_available vol-0abc
      The value "$(awk '$1 > 6.25 { over++ } $1 == 5 { pinned++ } END { print (over + 0 == 0 && pinned + 0 < 5) ? "spread" : "over=" over + 0 " pinned=" pinned + 0 }' "$SLEEPS")" should equal spread
    End
  End

  Describe 'command line'
    # Stub curl and aws for an instance that has created 16 detached volumes;
    # create-volume fails, so a run that gets past the limits exits 1.
    # shellcheck disable=SC2016
    setup() {
      STUB_DIR="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.cli-bin"
      CFG="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.cli-config.json"
      CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.cli-aws-calls"
      mkdir -p "$STUB_DIR"
      : > "$CALLS"
      export CALLS
      echo '{"volume": {"type": "gp3", "iops": 3000, "throughput": 125, "encrypted": 1},
        "limits": {"max_logical_volume_size": 8000, "max_ebs_volume_count": 16}}' > "$CFG"
      printf '%s\n' '#!/bin/sh' 'case "$*" in' \
        '  *api/token*) echo token ;;' \
        '  *availability-zone*) echo us-west-2a ;;' \
        '  *instance-id*) echo i-0123 ;;' \
        'esac' > "$STUB_DIR/curl"
      printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$CALLS"' 'case "$*" in' \
        "  *describe-volumes*) jq -nc '{Volumes: [range(16) | {Size: 10, Attachments: []}]}' ;;" \
        '  *) exit 1 ;;' \
        'esac' > "$STUB_DIR/aws"
      chmod +x "$STUB_DIR/curl" "$STUB_DIR/aws"
    }
    Before 'setup'

    create_ebs_volume() {
      env -u SHELLSPEC_VERSION PATH="$STUB_DIR:$PATH" EBS_AUTOSCALE_CONFIG_FILE="$CFG" \
        sh "$(script_path bin/create-ebs-volume)" "$@"
    }

    It 'defaults the created volume limit to --max-attached-volumes'
      When run create_ebs_volume --size 100 --max-attached-volumes 32
      The status should equal 1
      The stderr should include 'could not create volume'
      The contents of file "$CALLS" should include 'create-volume'
    End

    It 'stops at an explicit --max-created-volumes'
      When run create_ebs_volume --size 100 --max-created-volumes 16 --max-attached-volumes 32
      The status should equal 3
      The stderr should include 'maximum number of created volumes reached (16)'
      The contents of file "$CALLS" should not include 'create-volume'
    End

    It 'documents its exit statuses in --help'
      When run create_ebs_volume --help
      The status should be success
      The output should include '0 on success, 3 when a limit forbids another volume, 1 on any other failure.'
    End
  End
End
