# Developer Documentation

## Local Testing

Run the shell specs with [shellspec](https://shellspec.info/):

```bash
make test-sh
```

Install shellspec first, e.g. `brew install shellspec`.
The specs stub `aws`, `lsblk`, and `df` on `PATH`, so they need no AWS account and make no network calls.

## Local Linting

Lint every script and spec with [ShellCheck](https://www.shellcheck.net/):

```bash
make lint-sh
```

The scripts target Amazon Linux 2023, where `/bin/sh` is bash, but are written to stay portable; `dash -n <file>` is a quick POSIX-syntax check.

## Layout

- `install.sh` / `uninstall.sh` install and remove the service and its volumes.
- `bin/ebs-autoscale` is the polling daemon; `bin/create-ebs-volume` creates and attaches one volume.
- `shared/utils.sh` holds the metadata, logging, config, and retry helpers.
- `config/` holds the rendered-config template and the logrotate rule.
- `service/systemd/` holds the unit and its install/uninstall scripts.
- `spec/` holds the shellspec suite.

## Verifying a Change Without an Instance

Render the runtime config from the installer without root or an instance:

```bash
EBS_AUTOSCALE_RENDER_ONLY=1 EBS_AUTOSCALE_CONFIG_FILE=/tmp/ebs.json \
    sh install.sh -m /scratch -s 300 -f lvm.ext4
jq empty /tmp/ebs.json
```

## Releasing

Cut a GitHub Release with a `vMAJOR.MINOR.PATCH` tag.
Launch templates should pin `EBS_AUTOSCALE_VERSION` to a release tag rather than resolving the latest release at boot.
