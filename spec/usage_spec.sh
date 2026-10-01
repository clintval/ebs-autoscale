# shellcheck shell=bash
# Globals below are consumed by the Included script and stubs are invoked
# indirectly by shellspec; shellcheck cannot follow the Include DSL.
# shellcheck disable=SC2034,SC2317,SC2329
Describe 'bin/ebs-autoscale get_autoscaled_usage'
  Include bin/ebs-autoscale

  setup() {
    INSTANCE_ID=i-0123; AWS_REGION=us-west-2
    CALLS="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.aws-calls"
    : > "$CALLS"
    export CALLS
    RESPONSE='{"Volumes":[]}'
    aws() {
      printf '%s\n' "$*" >> "$CALLS"
      printf '%s' "$RESPONSE"
    }
  }
  Before 'setup'

  # volume SIZE INSTANCE: one created volume, attached to INSTANCE (or
  # detached when INSTANCE is empty), with the creation tag.
  volume() {
    jq -nc --argjson size "$1" --arg iid "$2" \
      '{Size: $size, Tags: [{Key: "amazon-ebs-autoscale-creation-time", Value: "t"}],
        Attachments: (if $iid == "" then [] else [{InstanceId: $iid}] end)}'
  }
  volumes() {
    local IFS=,
    printf '{"Volumes":[%s]}' "$*"
  }

  It 'makes a single describe-volumes call for both the count and the size'
    RESPONSE=$(volumes "$(volume 100 i-0123)" "$(volume 200 i-0123)")
    When call get_autoscaled_usage
    The output should equal '2 300'
    The value "$(wc -l < "$CALLS" | tr -d ' ')" should equal 1
  End

  It 'filters on the source-instance tag'
    When call get_autoscaled_usage
    The output should equal '0 0'
    The contents of file "$CALLS" should include 'Name=tag:source-instance,Values=i-0123'
  End

  It 'does not count volumes attached to another instance'
    RESPONSE=$(volumes "$(volume 100 i-0123)" "$(volume 200 i-9999)")
    When call get_autoscaled_usage
    The output should equal '1 300'
  End

  It 'does not count detached volumes but still sums their size'
    RESPONSE=$(volumes "$(volume 100 i-0123)" "$(volume 200 '')")
    When call get_autoscaled_usage
    The output should equal '1 300'
  End

  It 'does not count attached volumes lacking the creation tag'
    RESPONSE=$(jq -nc --arg iid i-0123 '{Volumes:[{Size:100, Attachments:[{InstanceId:$iid}]}]}')
    When call get_autoscaled_usage
    The output should equal '0 100'
  End

  It 'reports zero when there are no volumes'
    When call get_autoscaled_usage
    The output should equal '0 0'
  End

  It 'fails without output when EC2 returns nothing'
    RESPONSE=''
    When call get_autoscaled_usage
    The status should be failure
    The output should equal ''
  End

  It 'fails without output when EC2 returns malformed output'
    RESPONSE='not json'
    When call get_autoscaled_usage
    The status should be failure
    The output should equal ''
  End

  It 'fails without output when the aws call fails'
    aws() { return 1; }
    When call get_autoscaled_usage
    The status should be failure
    The output should equal ''
  End

  # The daemon runs under /bin/sh, which is bash in POSIX mode on Amazon Linux
  # 2023, while the suite runs under plain bash.
  It 'works when sourced by bash in POSIX mode'
    STUB_DIR="${SHELLSPEC_TMPBASE}/${SHELLSPEC_SPECFILE##*/}.posix-bin"
    mkdir -p "$STUB_DIR"
    printf '#!/bin/sh\ncat <<JSON\n%s\nJSON\n' "$(volumes "$(volume 100 i-0123)" "$(volume 50 i-0123)")" > "$STUB_DIR/aws"
    chmod +x "$STUB_DIR/aws"
    export INSTANCE_ID AWS_REGION
    # shellcheck disable=SC2016
    When run env PATH="$STUB_DIR:$PATH" bash --posix -c '. "$1"; get_autoscaled_usage' _ "$(script_path bin/ebs-autoscale)"
    The status should be success
    The output should equal '2 150'
    The stderr should equal ''
  End
End
