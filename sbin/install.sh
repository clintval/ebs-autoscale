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

# Installs ebs-autoscale on Amazon Linux 2023. Renders the runtime config,
# installs the scripts and the systemd unit, creates the initial lvm.ext4
# volume, and mounts it. lvm.ext4 is the only supported filesystem.

# 'local' is supported by dash and bash, the shells this runs under on AL2023.
# shellcheck disable=SC3043

set -eu

PREFIX=/usr/local/ebs-autoscale
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${EBS_AUTOSCALE_CONFIG_FILE:=/etc/ebs-autoscale.json}"

MOUNTPOINT=/scratch
SIZE=300
VOLUMETYPE=gp3
VOLUMEIOPS=3000
VOLUMETHROUGHPUT=125
MIN_EBS_VOLUME_SIZE=150
MAX_EBS_VOLUME_SIZE=1500
MAX_LOGICAL_VOLUME_SIZE=8000
MAX_ATTACHED_VOLUMES=16
INITIAL_UTILIZATION_THRESHOLD=50
MIN_FREE_SPACE=0
# Track explicit use so the default threshold does not trip the conflict check.
THRESHOLD_GIVEN=0
MIN_FREE_SPACE_GIVEN=0
DETECTION_INTERVAL=2
ENCRYPTED=1
FILE_SYSTEM=lvm.ext4
DEVICE=""

USAGE=$(cat <<USAGE_EOF
Install ebs-autoscale (Amazon Linux 2023, lvm.ext4, systemd).

    $0 [options] [-m <mount-point>]

Options

    -m, --mountpoint MOUNTPOINT          Mount point (default: /scratch)
    -s, --initial-size SIZE_GB           Initial volume size (default: 300).
                                         Ignored if --initial-device is given.
    -d, --initial-device DEVICE          Use an existing block device instead of
                                         creating the first volume.
    -f, --file-system lvm.ext4           Filesystem (only lvm.ext4 is supported).
    -t, --volume-type VOLUMETYPE         EBS volume type (default: gp3).
    --volume-iops N                      IOPS for gp3/io1/io2 (default: 3000).
    --volume-throughput N                Throughput MiB/s for gp3 (default: 125).
    --min-ebs-volume-size SIZE_GB        Min size of new volumes (default: 150).
    --max-ebs-volume-size SIZE_GB        Max size of new volumes (default: 1500).
    --max-total-created-size SIZE_GB     Max total created size (default: 8000).
    --max-attached-volumes N             Max attached volumes (default: 16).
    --initial-utilization-threshold N    Scale-up threshold percent (default: 50).
                                         Cannot be combined with --min-free-space.
    --min-free-space SIZE_GB             Grow when free space falls below SIZE_GB;
                                         replaces the utilization thresholds.
    --not-encrypted                      Create unencrypted volumes.
    -h, --help                           Print help and exit.

Environment

    EBS_AUTOSCALE_CONFIG_FILE   Rendered config path (default: /etc/ebs-autoscale.json).
    EBS_AUTOSCALE_RENDER_ONLY   If set, render the config and exit (no install).
USAGE_EOF
)

while [ "$#" -gt 0 ]; do
    case "$1" in
        -m|--mountpoint)                    MOUNTPOINT="$2"; shift 2 ;;
        -s|--initial-size)                  SIZE="$2"; shift 2 ;;
        -d|--initial-device)                DEVICE="$2"; shift 2 ;;
        -f|--file-system)                   FILE_SYSTEM="$2"; shift 2 ;;
        -t|--volume-type)                   VOLUMETYPE="$2"; shift 2 ;;
        --volume-iops)                      VOLUMEIOPS="$2"; shift 2 ;;
        --volume-throughput)                VOLUMETHROUGHPUT="$2"; shift 2 ;;
        --min-ebs-volume-size)              MIN_EBS_VOLUME_SIZE="$2"; shift 2 ;;
        --max-ebs-volume-size)              MAX_EBS_VOLUME_SIZE="$2"; shift 2 ;;
        --max-total-created-size)           MAX_LOGICAL_VOLUME_SIZE="$2"; shift 2 ;;
        --max-attached-volumes)             MAX_ATTACHED_VOLUMES="$2"; shift 2 ;;
        --initial-utilization-threshold)    INITIAL_UTILIZATION_THRESHOLD="$2"; THRESHOLD_GIVEN=1; shift 2 ;;
        --min-free-space)                   MIN_FREE_SPACE="$2"; MIN_FREE_SPACE_GIVEN=1; shift 2 ;;
        --not-encrypted)                    ENCRYPTED=0; shift ;;
        -i|--imdsv2)
            echo "warning: --imdsv2 is deprecated and ignored; IMDSv2 is always used" >&2
            shift ;;
        -h|--help)                          echo "$USAGE"; exit 0 ;;
        *)                                  echo "error: unsupported argument $1" >&2; echo "$USAGE" >&2; exit 1 ;;
    esac
done

if [ "$FILE_SYSTEM" != "lvm.ext4" ]; then
    echo "error: unsupported --file-system '${FILE_SYSTEM}'." >&2
    echo "Only lvm.ext4 is supported; btrfs is unavailable in the Amazon Linux 2023 default repositories." >&2
    exit 1
fi

if [ "$THRESHOLD_GIVEN" -eq 1 ] && [ "$MIN_FREE_SPACE_GIVEN" -eq 1 ]; then
    echo "error: --initial-utilization-threshold and --min-free-space cannot be combined; --min-free-space replaces the utilization thresholds." >&2
    exit 1
fi

# 0 means off, so an explicit 0 would silently do nothing, and a leading zero
# would be read as octal by the daemon's arithmetic.
if [ "$MIN_FREE_SPACE_GIVEN" -eq 1 ]; then
    case "$MIN_FREE_SPACE" in
        ''|*[!0-9]*|0*)
            echo "error: --min-free-space must be a positive integer number of GB, got '${MIN_FREE_SPACE}'." >&2
            exit 1 ;;
    esac
fi

# Strip a trailing slash so downstream mountpoint comparisons are stable.
MOUNTPOINT=${MOUNTPOINT%/}
[ -n "$MOUNTPOINT" ] || MOUNTPOINT=/

[ -n "${EBS_AUTOSCALE_DEBUG:-}" ] && set -x

# Render the runtime config before anything reads it (the config-before-use
# ordering that upstream head got wrong, breaking the lvm.ext4 install).
render_config() {
    sed \
        -e "s#%%MOUNTPOINT%%#${MOUNTPOINT}#" \
        -e "s#%%FILESYSTEM%%#${FILE_SYSTEM}#" \
        -e "s#%%VOLUMETYPE%%#${VOLUMETYPE}#" \
        -e "s#%%VOLUMEIOPS%%#${VOLUMEIOPS}#" \
        -e "s#%%VOLUMETHROUGHPUT%%#${VOLUMETHROUGHPUT}#" \
        -e "s#%%ENCRYPTED%%#${ENCRYPTED}#" \
        -e "s#%%DETECTIONINTERVAL%%#${DETECTION_INTERVAL}#" \
        -e "s#%%MINEBSVOLUMESIZE%%#${MIN_EBS_VOLUME_SIZE}#" \
        -e "s#%%MAXEBSVOLUMESIZE%%#${MAX_EBS_VOLUME_SIZE}#" \
        -e "s#%%MAXLOGICALVOLUMESIZE%%#${MAX_LOGICAL_VOLUME_SIZE}#" \
        -e "s#%%MAXATTACHEDVOLUMES%%#${MAX_ATTACHED_VOLUMES}#" \
        -e "s#%%INITIALUTILIZATIONTHRESHOLD%%#${INITIAL_UTILIZATION_THRESHOLD}#" \
        -e "s#%%MINFREESPACE%%#${MIN_FREE_SPACE}#" \
        "${ROOT}/config/ebs-autoscale.json" > "$EBS_AUTOSCALE_CONFIG_FILE"
}

render_config

if [ -n "${EBS_AUTOSCALE_RENDER_ONLY:-}" ]; then
    echo "rendered config to ${EBS_AUTOSCALE_CONFIG_FILE}" >&2
    exit 0
fi

export EBS_AUTOSCALE_CONFIG_FILE
# shellcheck source=shared/utils.sh
. "${ROOT}/shared/utils.sh"

# Install executables and shared code with explicit modes so a restrictive
# umask (as in a cloud-init boothook) cannot make them unreadable.
mkdir -p "${PREFIX}/bin" "${PREFIX}/shared"
cp "${ROOT}/bin/create-ebs-volume" "${PREFIX}/bin/create-ebs-volume"
cp "${ROOT}/bin/ebs-autoscale" "${PREFIX}/bin/ebs-autoscale"
chmod 755 "${PREFIX}/bin/create-ebs-volume" "${PREFIX}/bin/ebs-autoscale"
cp "${ROOT}/shared/utils.sh" "${PREFIX}/shared/utils.sh"
chmod 644 "${PREFIX}/shared/utils.sh"
ln -sf "${PREFIX}/bin/create-ebs-volume" /usr/local/bin/create-ebs-volume
ln -sf "${PREFIX}/bin/ebs-autoscale" /usr/local/bin/ebs-autoscale

cp "${ROOT}/config/ebs-autoscale.logrotate" /etc/logrotate.d/ebs-autoscale
chmod 644 /etc/logrotate.d/ebs-autoscale
chmod 644 "$EBS_AUTOSCALE_CONFIG_FILE"

# Create the mount point.
if [ -e "$MOUNTPOINT" ] && [ ! -d "$MOUNTPOINT" ]; then
    echo "error: ${MOUNTPOINT} exists but is not a directory" >&2
    exit 1
fi
mkdir -p "$MOUNTPOINT"

# Create the initial volume unless an existing device was provided.
if [ -z "$DEVICE" ] || [ ! -b "$DEVICE" ]; then
    DEVICE=$("${PREFIX}/bin/create-ebs-volume" --size "$SIZE" --type "$VOLUMETYPE")
fi

# Build the lvm.ext4 filesystem and mount it.
VG=$(get_config_value .lvm.volume_group)
LV=$(get_config_value .lvm.logical_volume)
pvcreate "$DEVICE"
vgcreate "$VG" "$DEVICE"
lvcreate "$VG" -n "$LV" -l 100%VG
mkfs.ext4 "/dev/mapper/${VG}-${LV}"
mount "/dev/mapper/${VG}-${LV}" "$MOUNTPOINT"
printf '/dev/mapper/%s-%s\t%s\text4\tdefaults\t0\t0\n' "$VG" "$LV" "$MOUNTPOINT" | tee -a /etc/fstab

# World-writable with the sticky bit: the mount is a shared scratch area where
# any user may create files but only remove their own.
chmod 1777 "$MOUNTPOINT"

# Install and start the systemd service (systemd is the only supported init).
if [ ! -d /run/systemd/system ]; then
    echo "error: systemd is required (no /run/systemd/system); only Amazon Linux 2023 with systemd is supported" >&2
    exit 1
fi
cp "${ROOT}/service/systemd/ebs-autoscale.service" /etc/systemd/system/ebs-autoscale.service
chmod 644 /etc/systemd/system/ebs-autoscale.service
systemctl daemon-reload
systemctl enable ebs-autoscale.service
# --no-block so starting from a cloud-init runcmd/boothook does not deadlock the
# same systemd transaction cloud-init is part of.
systemctl start --no-block ebs-autoscale.service
