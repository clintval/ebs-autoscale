# shellcheck shell=bash
# Stubs are invoked through shellspec, which shellcheck cannot follow.
# shellcheck disable=SC2317,SC2329
Describe 'bin/ebs-autoscale now_seconds'
  Include bin/ebs-autoscale

  no_proc_uptime() { [ ! -r /proc/uptime ]; }
  Skip if 'there is no /proc/uptime' no_proc_uptime

  It 'prints whole seconds of uptime'
    When call now_seconds
    The output should match pattern '[0-9]*'
    The output should not include '.'
  End
End
