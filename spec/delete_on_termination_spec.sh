# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'shared/utils.sh enable_delete_on_termination'
  Include shared/utils.sh

  setup() {
    INSTANCE_ID=i-0123; AWS_REGION=us-west-2
    CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.aws-calls"
    : > "$CALLS"
    sleep() { :; }
    aws() { printf '%s\n' "$*" >> "$CALLS"; return "${MODIFY_RC:-0}"; }
  }
  Before 'setup'

  calls() { wc -l < "$CALLS" | tr -d ' '; }

  It 'sets DeleteOnTermination on this instance by BDM name'
    When call enable_delete_on_termination /dev/sdf vol-0abc
    The status should be success
    The contents of file "$CALLS" should include '--instance-id i-0123'
    The contents of file "$CALLS" should include 'DeviceName=/dev/sdf,Ebs={DeleteOnTermination=true,VolumeId=vol-0abc}'
  End

  It 'retries five times, logs an ERR, and fails when the call keeps failing'
    MODIFY_RC=1
    When call enable_delete_on_termination /dev/sdf vol-0abc
    The status should be failure
    The result of function calls should equal 5
    The stderr should include 'DeleteOnTermination NOT enabled'
  End

  It 'reports success when the log cannot be written'
    EBS_AUTOSCALE_LOG_FILE=/nonexistent/ebs-autoscale.log
    When call enable_delete_on_termination /dev/sdf vol-0abc
    The status should be success
    The stderr should be present
  End
End
