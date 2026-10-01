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

  Describe 'space_is_low'
    GB=1073741824
    setup() { THRESHOLD=50; MIN_FREE_SPACE=0; }
    Before 'setup'

    Describe 'in percentage mode'
      It 'is low at the threshold'
        When call space_is_low 999999999999 50
        The status should be success
      End
      It 'is not low under the threshold, however little space is left'
        When call space_is_low 1 49
        The status should be failure
      End
      It 'is not low when the utilization is empty'
        When call space_is_low 1 ''
        The status should be failure
      End
      It 'follows the device-count threshold'
        THRESHOLD=80
        When call space_is_low 1 79
        The status should be failure
      End
    End

    Describe 'in free-space mode'
      setup_floor() { MIN_FREE_SPACE=100; }
      Before 'setup_floor'

      It 'is low when free space is under the floor even at low utilization'
        When call space_is_low $(( 99 * GB )) 5
        The status should be success
      End
      It 'is low for a floor too large to express in bytes'
        MIN_FREE_SPACE=107374182400
        When call space_is_low $(( 99 * GB )) 5
        The status should be success
      End
      It 'is not low when free space equals the floor'
        When call space_is_low $(( 100 * GB )) 99
        The status should be failure
      End
      It 'is not low when free space is over the floor even at 95% utilization'
        When call space_is_low $(( 101 * GB )) 95
        The status should be failure
      End
      It 'is low one byte under the floor'
        When call space_is_low $(( 100 * GB - 1 )) 5
        The status should be success
      End
      It 'ignores the utilization threshold'
        THRESHOLD=10
        When call space_is_low $(( 500 * GB )) 95
        The status should be failure
      End
      It 'is not low when free space is unknown'
        When call space_is_low '' 95
        The status should be failure
      End
    End
  End

  Describe 'calc_new_size'
    setup() { MIN_EBS_VOLUME_SIZE=150; MAX_EBS_VOLUME_SIZE=1500; MAX_LOGICAL_VOLUME_SIZE=8000; }
    Before 'setup'

    # New-volume size climbs with the device count, clamped to the configured
    # min/max, so a busy instance grows in larger steps.
    It 'uses the minimum for the first few devices'
      When call calc_new_size 1 0
      The output should equal 150
    End
    It 'steps up in the 4-6 device band'
      When call calc_new_size 5 0
      The output should equal 300
    End
    It 'steps up again in the 7-10 device band'
      When call calc_new_size 8 0
      The output should equal 1000
    End
    It 'caps at the max beyond 10 devices'
      When call calc_new_size 11 0
      The output should equal 1500
    End
    It 'shrinks to what is left under the max total size'
      When call calc_new_size 11 7700
      The output should equal 300
    End
    It 'covers a shortfall larger than the step'
      When call calc_new_size 1 0 700
      The output should equal 700
    End
    It 'keeps the step when the shortfall is smaller'
      When call calc_new_size 5 0 200
      The output should equal 300
    End
    It 'caps a shortfall at the max volume size'
      When call calc_new_size 1 0 5000
      The output should equal 1500
    End
    It 'caps a shortfall at what is left under the max total size'
      When call calc_new_size 1 7500 700
      The output should equal 500
    End
    It 'does not turn a non-numeric size into the whole remaining budget'
      MAX_EBS_VOLUME_SIZE=null
      When call calc_new_size 11 300
      The output should equal null
      The stderr should be present
    End
  End
End
