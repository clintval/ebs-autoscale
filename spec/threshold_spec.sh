# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/ebs-autoscale scaling ladders'
  Include bin/ebs-autoscale

  Describe 'calc_threshold'
    # The trigger threshold rises with the device count so that later additions
    # are progressively less eager.
    Parameters
      0  50
      3  50
      4  80
      6  80
      7  90
      20 90
    End
    Example "$1 devices -> $2%"
      INITIAL_UTILIZATION_THRESHOLD=50
      When call calc_threshold "$1"
      The output should equal "$2"
    End
  End

  Describe 'calc_new_size'
    setup() { MIN_EBS_VOLUME_SIZE=150; MAX_EBS_VOLUME_SIZE=1500; }
    Before 'setup'

    # New-volume size climbs with the device count, clamped to the configured
    # min/max, so a busy instance grows in larger steps.
    It 'uses the minimum for the first few devices'
      When call calc_new_size 1
      The output should equal 150
    End
    It 'steps up in the 4-6 device band'
      When call calc_new_size 5
      The output should equal 300
    End
    It 'steps up again in the 7-10 device band'
      When call calc_new_size 8
      The output should equal 1000
    End
    It 'caps at the max beyond 10 devices'
      When call calc_new_size 11
      The output should equal 1500
    End
  End
End
