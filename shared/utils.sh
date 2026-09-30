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
        # Not an if: an untaken if leaves $? at 0, losing the command's status.
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

starting() {
    loginfo "starting ebs-autoscale"
}

stopping() {
    loginfo "stopping ebs-autoscale"
}
