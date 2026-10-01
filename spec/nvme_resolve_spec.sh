# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/create-ebs-volume NVMe device resolution'
  Include bin/create-ebs-volume

  Describe 'match_nvme_device'
    # The kernel NVMe serial equals the volume id with dashes removed, so the
    # serial path needs no external tooling.
    It 'matches by kernel-reported NVMe serial'
      lsblk() { echo "vol0abc123"; }
      When call match_nvme_device /dev/nvme1n1 vol-0abc123 vol0abc123
      The status should be success
    End

    # When the serial is unavailable it must fall back to ebsnvme-id; the binary
    # is injectable via EBSNVME.
    It 'falls back to ebsnvme-id when the serial does not match'
      lsblk() { printf ''; }
      EBSNVME="${SHELLSPEC_TMPBASE}/ebsnvme-stub"
      printf '#!/bin/sh\necho "Volume ID: vol-0abc123"\n' > "$EBSNVME"
      chmod +x "$EBSNVME"
      export EBSNVME
      When call match_nvme_device /dev/nvme1n1 vol-0abc123 vol0abc123
      The status should be success
    End

    It 'does not match an unrelated volume'
      lsblk() { echo "volDIFFERENT"; }
      EBSNVME="${SHELLSPEC_TMPBASE}/ebsnvme-none"
      printf '#!/bin/sh\necho "Volume ID: vol-other"\n' > "$EBSNVME"
      chmod +x "$EBSNVME"
      export EBSNVME
      When call match_nvme_device /dev/nvme9n1 vol-0abc123 vol0abc123
      The status should be failure
    End
  End

  Describe 'resolve_nvme_device'
    # A volume that never surfaces must be a bounded, logged error rather than
    # the unbounded `while true` hang upstream has on Nitro.
    It 'times out instead of hanging when no device appears'
      _nvme_candidates() { :; }
      EBS_AUTOSCALE_NVME_TIMEOUT=1
      When call resolve_nvme_device vol-0deadbeef
      The status should be failure
      The stderr should include 'timed out'
      The file "$EBS_AUTOSCALE_LOG_FILE" should be exist
    End
  End
End
