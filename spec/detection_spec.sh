# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/ebs-autoscale free-space detection'
  Include bin/ebs-autoscale

  Describe 'read_fs_stats'
    # df --output keeps the columns fixed; parsing the last line makes it
    # immune to df wrapping a long device name onto a second row.
    It 'parses size, used, avail, and integer percent'
      df() { printf '%s\n' '    Size    Used   Avail Use%' '1000000000 250000000 750000000 25%'; }
      When call read_fs_stats /scratch
      The output should equal '1000000000 250000000 750000000 25'
    End

    It 'reads the data row even if earlier output would shift columns'
      df() { printf '%s\n' 'Size Used Avail Use%' '2000 1900 100 95%'; }
      When call read_fs_stats /scratch
      The word 4 of output should equal 95
    End
  End

  Describe 'can_grow'
    setup() { MAX_EBS_VOLUME_COUNT=16; MAX_LOGICAL_VOLUME_SIZE=8000; MIN_EBS_VOLUME_SIZE=150; }
    Before 'setup'

    # The ceiling is on autoscaled bytes, so a large local instance-store in
    # the same volume group must not stop growth, and reaching the ceiling must.
    It 'allows growth below both limits'
      When call can_grow 2 500
      The status should be success
    End
    It 'stops once the autoscaled size ceiling is reached'
      When call can_grow 2 8000
      The status should be failure
    End
    It 'stops once less than the minimum volume size is left'
      When call can_grow 2 7851
      The status should be failure
    End
    It 'stops once the device count ceiling is reached'
      When call can_grow 16 100
      The status should be failure
    End
  End
End
