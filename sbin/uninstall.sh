#!/bin/sh
# Copyright Amazon.com, Inc. or its affiliates.
# Copyright © 2026 Clint Valentine (modifications).
#
# Stops and removes the ebs-autoscale service, unmounts the filesystem, and
# detaches and deletes every EBS volume this instance created. Amazon Linux
# 2023, systemd only.

# 'local' is supported by dash and bash, the shells this runs under on AL2023.
# shellcheck disable=SC3043

set -eu

PREFIX=/usr/local/ebs-autoscale
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${EBS_AUTOSCALE_CONFIG_FILE:=/etc/ebs-autoscale.json}"
export EBS_AUTOSCALE_CONFIG_FILE

if [ -f "${PREFIX}/shared/utils.sh" ]; then
    # shellcheck source=shared/utils.sh
    . "${PREFIX}/shared/utils.sh"
else
    # shellcheck source=shared/utils.sh
    . "${ROOT}/shared/utils.sh"
fi
initialize

MOUNTPOINT=$(get_config_value .mountpoint)

# Stop and remove the systemd unit.
if [ -d /run/systemd/system ]; then
    systemctl stop ebs-autoscale.service || true
    systemctl disable ebs-autoscale.service || true
    rm -f /etc/systemd/system/ebs-autoscale.service
    systemctl daemon-reload
else
    echo "warning: systemd not detected; skipping service removal" >&2
fi

# Unmount the filesystem if mounted.
if mountpoint -q "$MOUNTPOINT" 2>/dev/null || mount | grep -q " ${MOUNTPOINT} "; then
    umount "$MOUNTPOINT" || echo "warning: could not unmount ${MOUNTPOINT}" >&2
fi

# Detach and delete every volume this instance created.
created_volumes=$(
    aws ec2 describe-volumes \
        --region "$AWS_REGION" \
        --filters "Name=tag:source-instance,Values=${INSTANCE_ID}" \
        --query 'Volumes[].VolumeId' \
        --output text
)

for volume in $created_volumes; do
    aws ec2 detach-volume --region "$AWS_REGION" --volume-id "$volume" >/dev/null
    aws ec2 wait volume-available --region "$AWS_REGION" --volume-ids "$volume"
    loginfo "volume ${volume} detached"
    aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$volume"
    aws ec2 wait volume-deleted --region "$AWS_REGION" --volume-ids "$volume"
    loginfo "volume ${volume} deleted"
done
