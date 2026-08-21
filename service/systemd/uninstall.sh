#!/bin/sh
set -eu

systemctl stop ebs-autoscale.service || true
systemctl disable ebs-autoscale.service || true

rm -f /etc/systemd/system/ebs-autoscale.service

systemctl daemon-reload
