#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#  1. Redistributions of source code must retain the above copyright notice,
#  this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#  notice, this list of conditions and the following disclaimer in the
#  documentation and/or other materials provided with the distribution.
#
#  3. Neither the name of the copyright holder nor the names of its
#  contributors may be used to endorse or promote products derived from
#  this software without specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
#  BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
#  FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
#  THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
#  INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
#  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
#  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
#  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
#  IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
#  POSSIBILITY OF SUCH DAMAGE.

# Shared helpers for ebs-autoscale, sourced by install.sh, bin/ebs-autoscale,
# and bin/create-ebs-volume. Targets Amazon Linux 2023, where /bin/sh is bash;
# written in portable shell so `dash -n` and `shellcheck -x` stay clean.

# 'local' is not in POSIX but is supported by dash and bash, the only shells
# this runs under; keep it for lexical scoping.
# shellcheck disable=SC3043

IMDS_IP=169.254.169.254
: "${EBS_AUTOSCALE_CONFIG_FILE:=/etc/ebs-autoscale.json}"
: "${EBS_AUTOSCALE_LOG_FILE:=/var/log/ebs-autoscale.log}"

# Fetch an instance-metadata value using IMDSv2. The session token is minted
# once by initialize() and exported as IMDS_TOKEN so it survives the command
# substitutions callers wrap this in; mint on demand if it is missing. `curl -f`
# makes an IMDS 401 a non-zero exit rather than empty-output-with-success, which
# is what silently produced empty region/instance-id on token-required instances.
get_metadata() {
    local key="$1"
    if [ -z "${IMDS_TOKEN:-}" ]; then
        IMDS_TOKEN=$(curl -sf -X PUT "http://${IMDS_IP}/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || {
            logerr "failed to obtain an IMDSv2 token"
            return 1
        }
    fi
    curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
        "http://${IMDS_IP}/latest/meta-data/${key}"
}

# Resolve region, availability zone, and instance id from IMDS, set the AWS CLI
# retry policy, and resolve the log-file path once. Aborts if IMDS returns
# nothing, which otherwise leaves every downstream `aws` call region-less.
initialize() {
    export AWS_RETRY_MODE=adaptive
    export AWS_MAX_ATTEMPTS=10
    export EBS_AUTOSCALE_CONFIG_FILE

    local log_file
    log_file=$(get_config_value .logging.log_file 2>/dev/null)
    [ -n "$log_file" ] && [ "$log_file" != "null" ] && EBS_AUTOSCALE_LOG_FILE="$log_file"
    export EBS_AUTOSCALE_LOG_FILE

    IMDS_TOKEN=$(curl -sf -X PUT "http://${IMDS_IP}/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    export IMDS_TOKEN

    AWS_AZ=$(get_metadata placement/availability-zone)
    AWS_REGION=$(printf '%s' "$AWS_AZ" | sed -e 's/[a-z]$//')
    INSTANCE_ID=$(get_metadata instance-id)
    export AWS_AZ AWS_REGION INSTANCE_ID

    if [ -z "$AWS_AZ" ] || [ -z "$INSTANCE_ID" ]; then
        logerr "IMDS returned empty metadata (az='${AWS_AZ}' instance-id='${INSTANCE_ID}'); check the instance profile and that IMDS is reachable"
        return 1
    fi
}

get_config_value() {
    local filter="$1"
    jq -r "$filter" "$EBS_AUTOSCALE_CONFIG_FILE"
}

# Structured logging. Lines are "<utc-timestamp> <LEVEL> <message>"; errors are
# also copied to stderr so journald captures them when running under systemd.
loginfo() {
    printf '%s INFO %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$EBS_AUTOSCALE_LOG_FILE"
}

logerr() {
    printf '%s ERR  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$EBS_AUTOSCALE_LOG_FILE" >&2
}

# Backwards-compatible alias for the upstream logging function name.
logthis() {
    loginfo "$1"
}

# Tag written to every volume this tool attaches; its presence distinguishes an
# autoscaled volume from one attached for other reasons.
CREATION_TAG=amazon-ebs-autoscale-creation-time

# read_owned_volumes: one describe-volumes for this instance's volumes, ignoring deleting, deleted and
# errored ones; sets OWNED_ATTACHED_COUNT, OWNED_ATTACHED_IDS, OWNED_CREATED_COUNT, OWNED_CREATED_GB,
# OWNED_CLAIMED_DEVICES and OWNED_MISSING_DOT ("VOLUME_ID DEVICE" pairs on one line), or fails.
# shellcheck disable=SC2034
read_owned_volumes() {
    local response summary
    response=$(aws ec2 describe-volumes \
        --region "$AWS_REGION" \
        --filters "Name=tag:source-instance,Values=${INSTANCE_ID}" \
        --output json 2>/dev/null) || return 1
    [ -n "$response" ] || return 1
    summary=$(printf '%s' "$response" | jq -r --arg iid "$INSTANCE_ID" --arg tag "$CREATION_TAG" '
        def str: type == "string";
        if (.Volumes | type) == "array" and all(.Volumes[];
            (.VolumeId | str) and (.State | str) and (.Size | type) == "number"
            and (.Attachments | type) == "array"
            and all(.Attachments[]; (.InstanceId | str) and (.State | str) and (.Device | str)))
        then . else error("unexpected describe-volumes response") end
        | [.Volumes[] | select(.State | . != "deleting" and . != "deleted" and . != "error")] as $volumes
        | [$volumes[]
            | select(any(.Tags[]?; .Key == $tag))
            | .VolumeId as $id
            | .Attachments[]? | select(.InstanceId == $iid and .State == "attached")
            | {$id, Device, DeleteOnTermination}] as $attached
        | "\($attached | length) \($volumes | length) \([$volumes[].Size] | add // 0)",
          ([$attached[].id] | join(" ")),
          ([$attached[] | select(.DeleteOnTermination != true) | .id, .Device] | join(" ")),
          ($volumes[].Attachments[]? | select(.InstanceId == $iid) | .Device)' 2>/dev/null) || return 1
    { read -r OWNED_ATTACHED_COUNT OWNED_CREATED_COUNT OWNED_CREATED_GB; read -r OWNED_ATTACHED_IDS; read -r OWNED_MISSING_DOT; } <<EOF
$summary
EOF
    OWNED_CLAIMED_DEVICES=$(printf '%s\n' "$summary" | sed '1,3d')
}

# _nvme_candidates: print attached NVMe namespace devices, one per line.
# Factored out (and overridable) so the resolver can be unit-tested.
_nvme_candidates() {
    local dev
    for dev in /dev/nvme*n1; do
        [ -b "$dev" ] && printf '%s\n' "$dev"
    done
}

# match_nvme_device DEV VOLUME_ID SERIAL -> 0 if DEV is the block device for the
# volume. Matches the kernel-reported NVMe serial first (no external tool), then
# falls back to ebsnvme-id in both its legacy (-v) and subcommand (id -v) forms.
# The ebsnvme-id binary can be overridden with EBSNVME for testing.
match_nvme_device() {
    local dev="$1"
    local target_vol="$2"
    local target_serial="$3"
    local serial vid ebsnvme
    serial=$(lsblk -dno SERIAL "$dev" 2>/dev/null)
    if [ "$serial" = "$target_serial" ] || [ "$serial" = "$target_vol" ]; then
        return 0
    fi
    ebsnvme=${EBSNVME:-$(command -v ebsnvme-id 2>/dev/null || echo /usr/sbin/ebsnvme-id)}
    vid=$("$ebsnvme" -v "$dev" 2>>"$EBS_AUTOSCALE_LOG_FILE" \
        || "$ebsnvme" id -v "$dev" 2>>"$EBS_AUTOSCALE_LOG_FILE")
    vid=$(printf '%s' "$vid" | awk '/Volume ID:/{print $3}')
    [ "$vid" = "$target_vol" ]
}

# retry ATTEMPTS COMMAND [ARG...]
# Runs COMMAND until it succeeds or ATTEMPTS is reached, with linear backoff.
# Returns the last command's exit status. Callers that must treat a specific
# non-zero status as success (e.g. lvresize returning 5) should wrap COMMAND.
retry() {
    local attempts="$1"
    shift
    local i=1
    local status=0
    while :; do
        # Use && rather than if so $? below holds the command's status.
        "$@" && return 0
        status=$?
        if [ "$i" -ge "$attempts" ]; then
            return "$status"
        fi
        logerr "command failed (status ${status}), attempt ${i}/${attempts}: $*"
        sleep $(( i * 2 ))
        i=$(( i + 1 ))
    done
}

# enable_delete_on_termination BDM_DEVICE VOLUME_ID -> 0 enabled, 2 not authorized after 1 attempt, 1 failed after 5 with retry's backoff.
enable_delete_on_termination() {
    local bdm_device="$1"
    local volume_id="$2"
    local i=1
    local err status
    while :; do
        err=$(aws ec2 modify-instance-attribute \
            --region "$AWS_REGION" \
            --instance-id "$INSTANCE_ID" \
            --block-device-mappings "DeviceName=${bdm_device},Ebs={DeleteOnTermination=true,VolumeId=${volume_id}}" 2>&1 >/dev/null) && break
        status=$?
        err=$(printf '%s' "$err" | tr '\n' ' ')
        case "$err" in
            *'(UnauthorizedOperation)'*|*'(AuthFailure)'*|*'(AccessDenied)'*)
                logerr "volume ${volume_id} DeleteOnTermination NOT enabled, so it may outlive the instance; not retrying an authorization error (grant ec2:ModifyInstanceAttribute): ${err}"
                return 2
                ;;
        esac
        if [ "$i" -ge 5 ]; then
            logerr "volume ${volume_id} DeleteOnTermination NOT enabled after retries; it may outlive the instance: ${err}"
            return 1
        fi
        logerr "modify-instance-attribute failed (status ${status}), attempt ${i}/5 for ${volume_id}: ${err}"
        sleep $(( i * 2 ))
        i=$(( i + 1 ))
    done
    loginfo "enabled DeleteOnTermination on ${volume_id} (${bdm_device})"
}

starting() {
    loginfo "starting ebs-autoscale"
}

stopping() {
    loginfo "stopping ebs-autoscale"
}
