# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'shared/utils.sh read_owned_volumes'
  Include shared/utils.sh

  setup() {
    INSTANCE_ID='i-0e1f2a3b4c5d6e7f8'; AWS_REGION=us-west-2
    CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.aws-calls"
    : > "$CALLS"
    RESPONSE=$(fixture describe-volumes.json)
    aws() {
      printf '%s\n' "$*" >> "$CALLS"
      printf '%s' "$RESPONSE"
    }
  }
  Before 'setup'

  # Prints the accounting as "ATTACHED|CREATED|GB|IDS|DEVICES" with the devices space-separated.
  summary() {
    read_owned_volumes || return
    printf '%s|%s|%s|%s|%s\n' "$OWNED_ATTACHED_COUNT" "$OWNED_CREATED_COUNT" "$OWNED_CREATED_GB" \
      "$OWNED_ATTACHED_IDS" "$(printf '%s' "$OWNED_CLAIMED_DEVICES" | tr '\n' ' ')"
  }
  # edit_volume INDEX UPDATE: applies a jq update to one volume of RESPONSE.
  edit_volume() {
    RESPONSE=$(printf '%s' "$RESPONSE" | jq -c --argjson i "$1" ".Volumes[\$i] |= ($2)")
  }

  It "summarizes this instance's volumes from one describe-volumes call"
    When call summary
    The output should equal '2|2|20|vol-0a1b2c3d4e5f60718 vol-0b2c3d4e5f6071829|/dev/sdf /dev/sdg'
    The value "$(wc -l < "$CALLS" | tr -d ' ')" should equal 1
    The contents of file "$CALLS" should include 'Name=tag:source-instance,Values=i-0e1f2a3b4c5d6e7f8'
  End

  It 'counts only attachments in the attached state but keeps a detaching device claimed'
    edit_volume 1 '.Attachments[0].State = "detaching"'
    When call summary
    The output should equal '1|2|20|vol-0a1b2c3d4e5f60718|/dev/sdf /dev/sdg'
  End

  It 'does not count an attached volume without the creation tag as attached'
    edit_volume 1 '.Tags |= map(select(.Key != "amazon-ebs-autoscale-creation-time"))'
    When call summary
    The output should equal '1|2|20|vol-0a1b2c3d4e5f60718|/dev/sdf /dev/sdg'
  End

  It 'does not count a volume attached to another instance as attached or claimed'
    edit_volume 1 '.Attachments[0].InstanceId = "i-0fedcba9876543210"'
    When call summary
    The output should equal '1|2|20|vol-0a1b2c3d4e5f60718|/dev/sdf'
  End

  It 'reports zero when there are no volumes'
    RESPONSE='{"Volumes":[]}'
    When call summary
    The output should equal '0|0|0||'
  End

  Describe 'fails closed'
    Parameters
      'when describe-volumes fails' fail ''
      'when describe-volumes returns nothing' succeed ''
      'on a response that is not JSON' succeed 'not json'
    End

    It "$1"
      RESPONSE=$3
      [ "$2" = succeed ] || aws() { return 254; }
      When call read_owned_volumes
      The status should be failure
    End
  End
End
