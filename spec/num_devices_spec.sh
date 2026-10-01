# shellcheck shell=bash
# Stubs are invoked indirectly by shellspec; shellcheck cannot follow the
# Include DSL.
# shellcheck disable=SC2317,SC2329
Describe 'bin/ebs-autoscale get_num_devices'
  Include bin/ebs-autoscale

  It 'counts the volumes in the describe-volumes response'
    aws() { echo '{"Volumes":[{"VolumeId":"vol-1"},{"VolumeId":"vol-2"}]}'; }
    When call get_num_devices
    The output should equal 2
    The stderr should equal ''
  End

  It 'reports zero when describe-volumes returns nothing'
    aws() { return 1; }
    When call get_num_devices
    The output should equal 0
    The stderr should equal ''
  End
End
