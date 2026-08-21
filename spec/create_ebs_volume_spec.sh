# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317
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
      CALLS="${SHELLSPEC_TMPBASE}/aws-calls"
      : > "$CALLS"
      export CALLS
      # Deterministic stubs for the device layer.
      get_next_logical_device() { printf '/dev/sdf'; }
      resolve_nvme_device() { printf '/dev/nvme1n1'; }
      # Record every aws invocation and return canned responses.
      aws() {
        printf '%s\n' "$*" >> "$CALLS"
        case "$*" in
          *describe-tags*)               echo '{"Tags":[]}' ;;
          *describe-volumes*)            echo '{"Volumes":[]}' ;;
          *create-volume*)               echo '{"VolumeId":"vol-0abc"}' ;;
          *"wait volume-available"*)     return "${WAIT_RC:-0}" ;;
          *attach-volume*)               return "${ATTACH_RC:-0}" ;;
          *modify-instance-attribute*)   return 0 ;;
          *delete-volume*)               return 0 ;;
          *)                             return 0 ;;
        esac
      }
    }
    Before 'setup'

    # Happy path returns the real NVMe device, and DeleteOnTermination must
    # reference the BDM name, not the NVMe path.
    It 'prints the real NVMe device and enables DeleteOnTermination by BDM name'
      When run create_and_attach_volume
      The status should be success
      The output should equal /dev/nvme1n1
      The contents of file "$CALLS" should include 'DeviceName=/dev/sdf'
    End

    # If the volume never becomes available it must be deleted, not leaked.
    It 'deletes the volume when it never becomes available'
      WAIT_RC=1
      When run create_and_attach_volume
      The status should be failure
      The contents of file "$CALLS" should include 'delete-volume'
      The stderr should include 'did not become available'
    End

    # A failed attach must also delete the just-created volume.
    It 'deletes the volume when the attach fails'
      ATTACH_RC=1
      When run create_and_attach_volume
      The status should be failure
      The stdout should equal ""
      The stderr should include 'could not attach'
      The contents of file "$CALLS" should include 'delete-volume'
    End
  End
End
