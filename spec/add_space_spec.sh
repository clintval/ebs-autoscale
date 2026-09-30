# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/ebs-autoscale add_space'
  Include bin/ebs-autoscale

  setup() {
    MOUNTPOINT=/scratch; MAX_EBS_VOLUME_COUNT=16; MAX_LOGICAL_VOLUME_SIZE=8000
    MIN_EBS_VOLUME_SIZE=150; MAX_EBS_VOLUME_SIZE=1500
    INSTANCE_ID=i-0123; AWS_REGION=us-west-2
    ORDER="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.order"
    : > "$ORDER"
    export ORDER
    # The daemon runs create-ebs-volume as a program; stand in for it.
    CREATE_VOLUME="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.fake-create-ebs-volume"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "create $*" >> "$ORDER"\necho "/dev/nvme1n1 /dev/sdf vol-0abc"\n' > "$CREATE_VOLUME"
    chmod +x "$CREATE_VOLUME"
    # No real retry backoff.
    sleep() { :; }
    grow_filesystem() { echo "grow $1" >> "$ORDER"; return "${GROW_RC:-0}"; }
    aws() {
      case "$*" in
        *modify-instance-attribute*) echo "delete-on-termination $*" >> "$ORDER"; return "${MODIFY_RC:-0}" ;;
      esac
    }
  }
  Before 'setup'

  modify_attempts() { grep -c '^delete-on-termination ' "$ORDER"; }

  It 'asks create-ebs-volume to skip DeleteOnTermination'
    When call add_space 1 0
    The contents of file "$ORDER" should include '--skip-delete-on-termination'
  End

  It 'grows the filesystem before setting DeleteOnTermination'
    When call add_space 1 0
    The line 2 of contents of file "$ORDER" should equal 'grow /dev/nvme1n1'
    The line 3 of contents of file "$ORDER" should start with 'delete-on-termination'
  End

  It 'sets DeleteOnTermination using the BDM name and volume id'
    When call add_space 1 0
    The contents of file "$ORDER" should include 'DeviceName=/dev/sdf,Ebs={DeleteOnTermination=true,VolumeId=vol-0abc}'
  End

  It 'still sets DeleteOnTermination when the filesystem grow fails'
    GROW_RC=1
    When call add_space 1 0
    The status should be failure
    The contents of file "$ORDER" should include 'delete-on-termination'
    The stderr should include 'failed to extend the filesystem'
  End

  It 'neither grows nor sets DeleteOnTermination when volume creation fails'
    printf '#!/bin/sh\nexit 1\n' > "$CREATE_VOLUME"
    When call add_space 1 0
    The status should be failure
    The stderr should include 'failed to create or attach'
    The contents of file "$ORDER" should not include 'grow'
    The contents of file "$ORDER" should not include 'delete-on-termination'
  End

  It 'logs an ERR but succeeds when only DeleteOnTermination fails'
    MODIFY_RC=1
    When call add_space 1 0
    The status should be success
    The stderr should include 'DeleteOnTermination NOT enabled'
    The result of function modify_attempts should equal 5
  End
End
