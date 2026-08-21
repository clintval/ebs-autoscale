# ebs-autoscale

[![CI](https://github.com/clintval/ebs-autoscale/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/clintval/ebs-autoscale/actions/workflows/test.yml?query=branch%3Amain)
[![ShellCheck](https://github.com/clintval/ebs-autoscale/actions/workflows/shellcheck.yml/badge.svg?branch=main)](https://github.com/clintval/ebs-autoscale/actions/workflows/shellcheck.yml?query=branch%3Amain)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-bash-4EAA25.svg)](https://www.gnu.org/software/bash/)

Autoscaling EBS-backed scratch storage for Amazon Linux 2023.

> [!NOTE]
> This is a community fork of the archived [awslabs/amazon-ebs-autoscale](https://github.com/awslabs/amazon-ebs-autoscale).
> It is not an AWS project and is not endorsed or supported by Amazon Web Services.

Install and mount an autoscaling `/scratch` volume with a single command:

```console
sh install.sh -m /scratch -s 300 -f lvm.ext4 -t gp3
```

## Introduction

`ebs-autoscale` keeps a local filesystem from running out of space by watching its utilization and attaching another EBS volume before it fills, growing an LVM logical volume onto each new device.
It is the elastic-scratch building block behind AWS Batch and Nextflow pipelines that write large, unpredictable intermediate files and want them on fast local block storage rather than a network filesystem.

The original project was archived by AWS in 2024 and no longer runs on current AMIs.
This fork forks upstream at `v2.4.7`, targets Amazon Linux 2023 on Nitro instances, and folds in the fixes that the community had scattered across forks and unmerged pull requests.

## Quick Start

Install onto an Amazon Linux 2023 instance whose profile has the [required permissions](#iam-permissions):

```bash
sh install.sh \
    -m /scratch \
    -s 300 \
    -f lvm.ext4 \
    -t gp3 \
    --volume-iops 4000 \
    --volume-throughput 250
```

The installer renders the runtime config, installs the daemon under systemd, creates the first EBS volume, and mounts it at `/scratch`.
Fill the mount past its threshold and a second volume is created, attached, and folded into the logical volume automatically.

For a full launch-template example that also points the Docker data-root at the scratch mount, see [`templates/cloud-config.yaml`](templates/cloud-config.yaml).

## Features

- **Amazon Linux 2023 and Nitro first.** Resolves the real `/dev/nvme*n1` device by its EBS volume serial, so it works on current-generation instances where the legacy `/dev/xvdb*` symlinks are unreliable.
- **IMDSv2 always.** No opt-in flag; works on instances that require metadata tokens.
- **lvm.ext4 only.** One well-tested path; btrfs is gone because it is unavailable in the AL2023 default repositories.
- **Does not leak volumes.** A volume that fails to become available or attach is deleted, and `DeleteOnTermination` is retried, so interrupted boots do not strand paid-for EBS.
- **systemd native.** Ships a hardened unit and starts it with `--no-block` so a cloud-init boothook cannot deadlock the boot.
- **Tested.** `shellcheck -x` plus a `shellspec` suite that needs no AWS account.

## Supported Platforms

| OS | Status |
| --- | --- |
| Amazon Linux 2023 | Supported and tested in CI |
| Amazon Linux 2 | Untested; likely works (systemd, `yum`/`dnf`) but not exercised |
| Amazon Linux 1, Ubuntu, CentOS | Unsupported |

Only Amazon Linux 2023 is a supported target.
The code avoids AL2023-only syntax, so Amazon Linux 2 will most likely work, but it is not tested and not a claim.

## Configuration

The installer accepts the following options:

```
-m, --mountpoint MOUNTPOINT          Mount point (default: /scratch)
-s, --initial-size SIZE_GB           Initial volume size (default: 300)
-d, --initial-device DEVICE          Use an existing block device for the mount
-f, --file-system lvm.ext4           Filesystem (only lvm.ext4 is supported)
-t, --volume-type VOLUMETYPE         EBS volume type (default: gp3)
    --volume-iops N                  IOPS for gp3/io1/io2 (default: 3000)
    --volume-throughput N            Throughput MiB/s for gp3 (default: 125)
    --min-ebs-volume-size SIZE_GB    Min size of new volumes (default: 150)
    --max-ebs-volume-size SIZE_GB    Max size of new volumes (default: 1500)
    --max-total-created-size SIZE_GB Max total created size (default: 8000)
    --max-attached-volumes N         Max attached volumes (default: 16)
    --initial-utilization-threshold N  Scale-up threshold percent (default: 50)
    --not-encrypted                  Create unencrypted volumes
```

The runtime config is written to `/etc/ebs-autoscale.json`; override the path with `EBS_AUTOSCALE_CONFIG_FILE`.
Set `EBS_AUTOSCALE_RENDER_ONLY=1` to render the config and exit without installing, which is useful for review.

The mount point is created world-writable with the sticky bit (`chmod 1777`), so any user may create files there but only remove their own, matching how a shared scratch area is used.

> [!TIP]
> Passing `--initial-device` skips the boot-time `create-volume` call.
> Pre-provisioning the first volume in the launch template's `BlockDeviceMappings` and pointing `--initial-device` at it avoids a burst of EC2 API calls at boot, which under heavy fleet churn can cause instances to fail to launch.

## IAM Permissions

The instance profile needs the following actions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:CreateTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumeStatus",
        "ec2:DescribeVolumeAttribute",
        "ec2:DescribeTags",
        "ec2:ModifyInstanceAttribute"
      ],
      "Resource": "*"
    }
  ]
}
```

`ec2:DetachVolume` is required by `uninstall.sh` and was missing from the upstream policy.
If you encrypt volumes with a customer-managed KMS key, also grant the instance role the usual `kms:CreateGrant`, `kms:GenerateDataKeyWithoutPlaintext`, and `kms:Decrypt` on that key.

> [!NOTE]
> `"Resource": "*"` is broad. It can be tightened with `ec2:ResourceTag`/`aws:RequestTag` conditions keyed on the `source-instance` tag this tool writes; that hardening is left to the operator.

## How It Works

The `ebs-autoscale` daemon polls `df` on the mount every couple of seconds.
When utilization crosses a threshold that rises with the number of attached volumes, it calls `create-ebs-volume`, which creates an encrypted EBS volume, attaches it, resolves its real NVMe device, enables `DeleteOnTermination`, and prints the device path.
The daemon then extends the LVM volume group onto the new device and grows the ext4 filesystem in place.

The scale-up ceiling is measured against the EBS this instance has created, not the total filesystem size, so a large local instance-store already in the volume group does not disable autoscaling.

## Differences from Upstream

This fork forks at `v2.4.7` and re-applies the good parts of the later, never-released IMDSv2 work by hand.
Each change is tied to the upstream issue it resolves:

- Resolve the real NVMe device by volume serial rather than waiting on a `/dev/xvdb*` symlink that never appears on Nitro ([#41](https://github.com/awslabs/amazon-ebs-autoscale/issues/41)).
- Always use IMDSv2 with a real token header, and fail loudly on a metadata 401 instead of silently proceeding with an empty region ([#63](https://github.com/awslabs/amazon-ebs-autoscale/issues/63), [#71](https://github.com/awslabs/amazon-ebs-autoscale/issues/71)).
- Delete a volume that fails to become available or attach, and retry `DeleteOnTermination`, so interrupted boots stop leaking volumes ([#30](https://github.com/awslabs/amazon-ebs-autoscale/issues/30)).
- Detect systemd with `/run/systemd/system` instead of a fragile heuristic that returned "unknown" on AL2023 ([#66](https://github.com/awslabs/amazon-ebs-autoscale/issues/66)).
- Start the service with `--no-block` so a cloud-init boothook cannot deadlock the boot ([#13](https://github.com/awslabs/amazon-ebs-autoscale/issues/13)).
- Export the config path before it is read, fixing the empty-volume-group install failure on later upstream commits ([#75](https://github.com/awslabs/amazon-ebs-autoscale/issues/75)).
- Build tag specifications with `jq` so tag values with spaces or metacharacters cannot corrupt the request ([#33](https://github.com/awslabs/amazon-ebs-autoscale/issues/33)), fix the trailing-slash and wrapped-`df` detection bugs ([#49](https://github.com/awslabs/amazon-ebs-autoscale/issues/49)), and correct the throughput config typo ([#59](https://github.com/awslabs/amazon-ebs-autoscale/pull/59)).

Removed: btrfs, the upstart and sysv init paths, the IMDSv1 fallback, the instance-store RAID helper, and non-Amazon distributions.

These fixes draw on the `myome`, `arvados`, `codeocean`, and `nubank` forks; see [`NOTICE`](NOTICE).

## Development and Testing

See the [contributing guide](./CONTRIBUTING.md) for more information.

> [!NOTE]
> This fork was refreshed with the help of Claude Code.
