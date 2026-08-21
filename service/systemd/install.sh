#!/bin/sh
set -eu

# Install the systemd unit into the local admin directory and start it.
cp ebs-autoscale.service /etc/systemd/system/ebs-autoscale.service
chmod 644 /etc/systemd/system/ebs-autoscale.service

systemctl daemon-reload
systemctl enable ebs-autoscale.service
# --no-block so starting from a cloud-init runcmd/boothook does not deadlock on
# the same systemd transaction cloud-init is part of.
systemctl start --no-block ebs-autoscale.service
