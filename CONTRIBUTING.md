# Developer Documentation

## Local Testing

Install shellspec first, e.g. `brew install shellspec`.

Run the shell specs with [shellspec](https://shellspec.info/):

```bash
make test-sh
```

The specs stub `aws`, `lsblk`, and `df` on `PATH`, so they need no AWS account and make no network calls.

## Local Linting

Lint every script and spec with [ShellCheck](https://www.shellcheck.net/):

```bash
make lint-sh
```

The scripts target Amazon Linux 2023, where `/bin/sh` is bash, but are written to stay portable.

## Verifying a Change Without an Instance

Render the runtime config from the installer without root or an instance:

```bash
EBS_AUTOSCALE_RENDER_ONLY=1 EBS_AUTOSCALE_CONFIG_FILE=/dev/stdout \
    sh sbin/install.sh -m /scratch -s 300 -f lvm.ext4 \
    | jq empty /dev/stdin
```

## End-to-End Testing

`scripts/e2e.sh` runs the full install on a real Amazon Linux 2023 instance, fills the scratch mount to force a scale-up, and asserts it grew and left no volumes behind, tearing every resource down afterward.
It uses your default AWS credentials and costs a few cents per run, so it is gated behind an environment variable:

```bash
make e2e   # equivalent to: EBS_AUTOSCALE_E2E=1 bash scripts/e2e.sh
```

Override the region or instance type with `AWS_REGION` and `E2E_INSTANCE_TYPE`, or set `E2E_KEEP=1` to leave the instance up for inspection.

## Releasing

Cut a GitHub Release with a `MAJOR.MINOR.PATCH` tag.
Launch templates should pin `EBS_AUTOSCALE_VERSION` to a release tag rather than resolving the latest release at boot.
