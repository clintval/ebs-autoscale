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
sh sbin/install.sh -m /scratch -s 300 -f lvm.ext4 -t gp3
```

## Introduction

The utility `ebs-autoscale` keeps a local filesystem from running out of space by watching its utilization and attaching another EBS volume before it fills, growing an LVM logical volume onto each new device.
It is the elastic-scratch building block behind AWS Batch and Nextflow pipelines that write large, unpredictably-sized intermediate files and want them on fast local block storage rather than a network filesystem.

The original project was archived by AWS in 2024 and no longer runs on current AMIs.
It forks upstream at `v2.4.7`, targets Amazon Linux 2023 on Nitro instances, and additionally folds in the fixes that were scattered across the community.

## Quick Start

Install onto an Amazon Linux 2023 instance whose profile has the [required permissions](#iam-permissions):

```bash
sh sbin/install.sh \
    -m /scratch \
    -s 300 \
    -f lvm.ext4 \
    -t gp3 \
    --volume-iops 4000 \
    --volume-throughput 250
```

The installer renders the runtime config, installs the daemon under systemd, creates the first EBS volume, and mounts it at `/scratch`.
Fill the mount past its threshold and a second volume is created, attached, and folded into the logical volume automatically.

## AWS Batch / ECS Node Bootstrap

The common way to use `ebs-autoscale` is from the `UserData` of an EC2 launch template, so every compute node instantiates with an elastic scratch volume.
IMDSv2, Nitro NVMe device resolution, systemd, and `lvm.ext4` are all handled by the installer.
The example below additionally contains some common ECS node tuning: raise file-descriptor limits and move the Docker data-root onto the scaling partition so image layers and container volumes grow with it.

```yaml
output: {all: '| tee -a /var/log/cloud-init-output.log'}

repo_update: true
repo_upgrade: security

packages:
  - jq
  - unzip
  - lvm2

runcmd:
  - set -euxo pipefail

  # Install the AWS CLI v2, which ebs-autoscale shells out to.
  - curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  - unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install -b /usr/bin

  # Stop the ECS agent and Docker while the scratch mount is set up.
  - systemctl stop ecs || true
  - systemctl stop docker || true

  # Install ebs-autoscale from a pinned release and mount /scratch as lvm.ext4.
  - EBS_AUTOSCALE_VERSION=1.0.0
  - mkdir -p /opt/ebs-autoscale
  - curl -sL "https://github.com/clintval/ebs-autoscale/archive/refs/tags/${EBS_AUTOSCALE_VERSION}.tar.gz" | tar xz --strip-components=1 -C /opt/ebs-autoscale
  - >-
    sh /opt/ebs-autoscale/sbin/install.sh
    -m /scratch
    -s 300
    -f lvm.ext4
    -t gp3
    --volume-iops 4000
    --volume-throughput 250
    > /var/log/ebs-autoscale-install.log 2>&1

  # Raise file-descriptor limits for container-heavy workloads.
  - echo "* soft nofile 64000" >> /etc/security/limits.conf
  - echo "* hard nofile 128000" >> /etc/security/limits.conf
  - sysctl -w fs.file-max=128000
  - sysctl -p

  # Move the Docker data-root onto the scratch partition.
  - mkdir -p /scratch/docker && mv /var/lib/docker/* /scratch/docker/ 2>/dev/null || true
  - mkdir -p /etc/docker
  - echo '{"data-root":"/scratch/docker"}' > /etc/docker/daemon.json

  # Restart Docker, then the ECS agent. --no-block avoids deadlocking cloud-init.
  - systemctl start docker
  - systemctl daemon-reload
  - systemctl start --no-block ecs
```

On the launch template itself, set `EbsOptimized: true` so the scratch volume gets dedicated EBS bandwidth, give it a small gp3 root volume (the scratch mount grows separately), and attach an `IamInstanceProfile` whose role has the [permissions below](#iam-permissions).

## Supported Platforms

| OS | Status |
| --- | --- |
| Amazon Linux 2023 | Supported and tested in CI |
| Amazon Linux 2 | Untested; likely works (systemd, `yum`/`dnf`) but not exercised |
| Amazon Linux 1, Ubuntu, CentOS | Unsupported |


## Configuration

The installer accepts the following options:

```
-m, --mountpoint MOUNTPOINT            Mount point (default: /scratch)
-s, --initial-size SIZE_GB             Initial volume size (default: 300)
-d, --initial-device DEVICE            Use an existing block device for the mount
-f, --file-system lvm.ext4             Filesystem (only lvm.ext4 is supported)
-t, --volume-type VOLUMETYPE           EBS volume type (default: gp3)
    --volume-iops N                    IOPS for gp3/io1/io2 (default: 3000)
    --volume-throughput N              Throughput MiB/s for gp3 (default: 125)
    --min-ebs-volume-size SIZE_GB      Min size of new volumes (default: 150)
    --max-ebs-volume-size SIZE_GB      Max size of new volumes (default: 1500)
    --max-total-created-size SIZE_GB   Max total created size (default: 8000)
    --max-attached-volumes N           Max attached volumes (default: 16)
    --initial-utilization-threshold N  Scale-up threshold percent (default: 50)
    --not-encrypted                    Create unencrypted volumes
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

## Development and Testing

See the [contributing guide](./CONTRIBUTING.md) for more information.
