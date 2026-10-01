#!/usr/bin/env bash
# End-to-end test for ebs-autoscale on a real Amazon Linux 2023 instance.
#
# Launches one EC2 instance, installs ebs-autoscale from the committed HEAD of
# this repository (shipped to the instance through a throwaway S3 object), fills
# /scratch past its utilization threshold, and asserts that the filesystem grew
# and a second EBS volume was attached. It then stops the daemon, attaches a
# tagged volume outside the volume group, restarts the daemon, and asserts the
# volume is folded in without another being created. It then sets a
# min_free_space floor over the free space at low utilization and asserts one
# volume sized to the shortfall lifts free space over it. Finally it terminates the
# instance and asserts that no autoscale volume was left behind, which is the
# real test of the DeleteOnTermination handling. Every resource is ephemeral
# and torn down on exit.
#
# This creates real AWS resources (one instance, a couple of small EBS volumes,
# an IAM role, a security group, and an S3 object) and costs a few cents per run.
#
# Requires: aws (v2), jq, git. Uses your default AWS credentials and region.
#
# Run:
#   EBS_AUTOSCALE_E2E=1 bash scripts/e2e.sh
#
# Environment overrides:
#   AWS_REGION          Region to run in (default: your profile's, else us-west-2)
#   E2E_INSTANCE_TYPE   Instance type (default: m5.large)
#   E2E_INITIAL_GB      Initial scratch volume size in GB (default: 10, at most 12)
#   E2E_KEEP            If set, skip teardown so you can inspect the instance
#   E2E_BUCKET          Reuse this S3 bucket instead of creating a throwaway one

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${EBS_AUTOSCALE_E2E:-}" ]]; then
  echo "Refusing to run: this launches real AWS resources and costs money." >&2
  echo "Re-run with EBS_AUTOSCALE_E2E=1 to proceed." >&2
  exit 2
fi

for tool in aws jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found on PATH" >&2; exit 1; }
done

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
INSTANCE_TYPE="${E2E_INSTANCE_TYPE:-m5.large}"
INITIAL_GB="${E2E_INITIAL_GB:-10}"
RUN_ID="ebs-autoscale-e2e-$(date -u +%Y%m%d%H%M%S)-$RANDOM"

log() { printf '[e2e] %s\n' "$*" >&2; }
die() { printf '[e2e] FAIL: %s\n' "$*" >&2; exit 1; }

# Past 12 GB, ext4's ~7% overhead keeps the free-space phase's one E2E_INITIAL_GB + 1 volume from clearing its floor.
if ! [[ "$INITIAL_GB" =~ ^[0-9]+$ ]] || (( INITIAL_GB > 12 )); then
  die "E2E_INITIAL_GB must be a whole number no larger than 12"
fi

# Populated as resources are created; cleanup tears them down in reverse.
INSTANCE_ID=""
TERMINATED=""
SG_ID=""
ROLE_NAME=""
PROFILE_NAME=""
BUCKET=""
BUCKET_CREATED=""
S3_KEY=""
TARBALL=""

cleanup() {
  local code=$?
  if [[ -n "${E2E_KEEP:-}" ]]; then
    log "E2E_KEEP set; leaving resources up. instance=$INSTANCE_ID sg=$SG_ID role=$ROLE_NAME bucket=$BUCKET"
    return
  fi
  log "tearing down"
  if [[ -n "$INSTANCE_ID" && -z "$TERMINATED" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
  fi
  # Belt-and-suspenders: delete any volume this instance created that outlived
  # it. DeleteOnTermination handles these in the normal case; this catches a
  # volume whose DoT was never set (the exact failure the test guards against).
  if [[ -n "$INSTANCE_ID" ]]; then
    local vol
    for vol in $(aws ec2 describe-volumes --region "$REGION" \
      --filters "Name=tag:source-instance,Values=${INSTANCE_ID}" "Name=status,Values=available" \
      --query 'Volumes[].VolumeId' --output text 2>/dev/null || true); do
      aws ec2 delete-volume --region "$REGION" --volume-id "$vol" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "$PROFILE_NAME" ]]; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
    aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ROLE_NAME" ]]; then
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name inline >/dev/null 2>&1 || true
    aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SG_ID" ]]; then
    local i
    for ((i = 0; i < 6; i++)); do
      if aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" >/dev/null 2>&1; then
        SG_ID=""
        break
      fi
      sleep 10
    done
    if [[ -n "$SG_ID" ]]; then
      log "warning: could not delete security group $SG_ID; delete it once its ENI drains"
    fi
  fi
  if [[ -n "$BUCKET" && -n "$S3_KEY" ]]; then
    aws s3 rm "s3://${BUCKET}/${S3_KEY}" --region "$REGION" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BUCKET_CREATED" ]]; then
    aws s3 rb "s3://${BUCKET}" --region "$REGION" >/dev/null 2>&1 || true
  fi
  [[ -n "$TARBALL" && -f "$TARBALL" ]] && rm -f "$TARBALL"
  log "teardown complete"
  exit "$code"
}
trap cleanup EXIT

# Run a shell command on the instance via SSM and print its stdout. Waits for
# the invocation to finish and fails the test if the command errored.
ssm_run() {
  local cmd="$1" cid status
  cid="$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "$RUN_ID" \
    --parameters "commands=[$(jq -Rn --arg c "$cmd" '$c')]" \
    --query 'Command.CommandId' --output text)"
  local i
  for ((i = 0; i < 60; i++)); do
    status="$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cid" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) aws ssm get-command-invocation --region "$REGION" \
                 --command-id "$cid" --instance-id "$INSTANCE_ID" \
                 --query 'StandardOutputContent' --output text; return 0 ;;
      Failed|Cancelled|TimedOut) die "SSM command '$cmd' -> $status" ;;
    esac
    sleep 5
  done
  die "SSM command '$cmd' did not finish in time"
}

owned_volume_count() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:source-instance,Values=${INSTANCE_ID}" \
    --query 'length(Volumes)' --output text
}

# Prints "VOLUME_ID SIZE_GB" for each volume this instance created.
owned_volumes() {
  aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:source-instance,Values=${INSTANCE_ID}" \
    --query 'Volumes[].[VolumeId,Size]' --output text
}

# Prints the last non-empty line of an ssm_run command's output.
ssm_last() {
  ssm_run "$1" | awk 'NF { last = $0 } END { print last }'
}

GIB=1073741824

log "region=$REGION type=$INSTANCE_TYPE run=$RUN_ID"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

AMI_ID="$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id \
  --query 'Parameter.Value' --output text)"
log "ami=$AMI_ID"

VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" ]] || die "no default VPC in $REGION; set one up or run elsewhere"
SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)"
[[ "$SUBNET_ID" != "None" ]] || die "no default subnet in $VPC_ID"

# Ship the committed HEAD to the instance via S3.
BUCKET="${E2E_BUCKET:-${RUN_ID}-${ACCOUNT_ID}}"
S3_KEY="${RUN_ID}.tar.gz"
TARBALL="$(mktemp -t ebs-autoscale-e2e).tar.gz"
git -C "$REPO" archive --format=tar.gz -o "$TARBALL" HEAD
if [[ -z "${E2E_BUCKET:-}" ]]; then
  aws s3 mb "s3://${BUCKET}" --region "$REGION" >/dev/null
  BUCKET_CREATED=1
fi
aws s3 cp "$TARBALL" "s3://${BUCKET}/${S3_KEY}" --region "$REGION" >/dev/null
log "uploaded code to s3://${BUCKET}/${S3_KEY}"

# IAM role: ebs-autoscale EC2 permissions + read of our object + SSM.
ROLE_NAME="$RUN_ID"
PROFILE_NAME="$RUN_ID"
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name inline \
  --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["ec2:AttachVolume","ec2:DetachVolume","ec2:CreateVolume","ec2:DeleteVolume","ec2:CreateTags","ec2:DescribeVolumes","ec2:DescribeVolumeStatus","ec2:DescribeVolumeAttribute","ec2:DescribeTags","ec2:ModifyInstanceAttribute"],
      "Resource": "*" },
    { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::${BUCKET}/${S3_KEY}" }
  ]
}
JSON
)"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null
log "created role/profile $ROLE_NAME; waiting for IAM propagation"
sleep 15

SG_ID="$(aws ec2 create-security-group --region "$REGION" \
  --group-name "$RUN_ID" --description "ebs-autoscale e2e ($RUN_ID)" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
log "security group $SG_ID (egress-only; SSM needs no inbound)"

USER_DATA="$(cat <<UD
#!/bin/bash
set -euxo pipefail
dnf install -y jq unzip lvm2 tar
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install -b /usr/bin
aws s3 cp "s3://${BUCKET}/${S3_KEY}" /tmp/ebs-autoscale.tar.gz --region ${REGION}
mkdir -p /opt/ebs-autoscale
tar xzf /tmp/ebs-autoscale.tar.gz -C /opt/ebs-autoscale
sh /opt/ebs-autoscale/sbin/install.sh -m /scratch -s ${INITIAL_GB} -f lvm.ext4 -t gp3 \
  --min-ebs-volume-size ${INITIAL_GB} --max-ebs-volume-size ${INITIAL_GB} \
  --initial-utilization-threshold 50 > /var/log/ebs-autoscale-install.log 2>&1
touch /var/lib/ebs-autoscale-e2e-installed
UD
)"

INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=${PROFILE_NAME}" \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${RUN_ID}}]" \
  --query 'Instances[0].InstanceId' --output text)"
log "launched instance $INSTANCE_ID; waiting for it to run"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

log "waiting for SSM registration"
for ((i = 0; i < 40; i++)); do
  ping="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)"
  [[ "$ping" == "Online" ]] && break
  sleep 15
done
[[ "${ping:-None}" == "Online" ]] || die "instance never registered with SSM"

log "waiting for the install to finish"
# shellcheck disable=SC2016  # expands on the instance, not here
ssm_run 'for i in $(seq 60); do [ -f /var/lib/ebs-autoscale-e2e-installed ] && exit 0; sleep 5; done; echo "install marker missing"; cat /var/log/ebs-autoscale-install.log 2>/dev/null; exit 1' >/dev/null

initial_size="$(ssm_run 'df -B1 --output=size /scratch | tail -n1 | tr -d " "')"
initial_count="$(owned_volume_count)"
log "installed: /scratch size=${initial_size}B, owned volumes=${initial_count}"
[[ "$initial_count" -ge 1 ]] || die "no autoscale volume after install"

log "filling /scratch past the threshold"
ssm_run "fallocate -l $(( INITIAL_GB * 8 / 10 ))G /scratch/e2e.fill" >/dev/null

log "waiting for the filesystem to grow"
grew=""
for ((i = 0; i < 24; i++)); do
  cur="$(ssm_run 'df -B1 --output=size /scratch | tail -n1 | tr -d " "')"
  if [[ "$cur" -gt "$initial_size" ]]; then grew="$cur"; break; fi
  sleep 5
done
[[ -n "$grew" ]] || die "/scratch did not grow (still ${initial_size}B)"
final_count="$(owned_volume_count)"
log "grew: /scratch size=${grew}B, owned volumes=${final_count}"
[[ "$final_count" -ge 2 ]] || die "expected >=2 autoscale volumes after growth, got ${final_count}"

VG="$(ssm_run 'jq -r .lvm.volume_group /etc/ebs-autoscale.json')"
[[ -n "$VG" ]] || die "could not read the volume group from /etc/ebs-autoscale.json"
# Prints "vg=[NAME]" for the device's volume group, empty when it is not a PV.
pv_vg() {
  ssm_run "echo \"vg=[\$(pvs --noheadings -o vg_name $1 2>/dev/null | tr -d ' ')]\""
}

log "stopping the daemon and attaching a volume outside the volume group"
ssm_run 'systemctl stop ebs-autoscale' >/dev/null
stray_dev="$(ssm_run "/usr/local/ebs-autoscale/bin/create-ebs-volume --size ${INITIAL_GB}" | awk 'NF { last = $0 } END { print last }')"
[[ "$stray_dev" == /dev/nvme* ]] || die "could not attach a stray volume (got '${stray_dev}')"
[[ "$(pv_vg "$stray_dev")" == "vg=[]" ]] || die "${stray_dev} joined a volume group before the daemon restarted"
stray_count="$(owned_volume_count)"
stray_size="$(ssm_run 'df -B1 --output=size /scratch | tail -n1 | tr -d " "')"
log "stray ${stray_dev} attached: owned volumes=${stray_count}, /scratch size=${stray_size}B"

log "restarting the daemon and waiting for it to fold ${stray_dev} into ${VG}"
ssm_run 'systemctl start ebs-autoscale' >/dev/null
folded=""
for ((i = 0; i < 24; i++)); do
  cur="$(ssm_run 'df -B1 --output=size /scratch | tail -n1 | tr -d " "')"
  if [[ "$(pv_vg "$stray_dev")" == "vg=[${VG}]" && "$cur" -gt "$stray_size" ]]; then folded="$cur"; break; fi
  sleep 5
done
[[ -n "$folded" ]] || die "the daemon did not fold ${stray_dev} into ${VG} and grow /scratch"
fold_logs="$(ssm_run "grep -c 'folding stray volume' /var/log/ebs-autoscale.log || true")"
[[ "$fold_logs" -ge 1 ]] || die "the daemon did not log the fold"
log "folded: /scratch size=${folded}B; waiting to confirm no extra volume is created"
sleep 20
[[ "$(owned_volume_count)" -eq "$stray_count" ]] || die "expected ${stray_count} owned volumes after the fold, got $(owned_volume_count)"

log "stopping the daemon to switch it to free-space mode"
ssm_run 'systemctl stop ebs-autoscale' >/dev/null
ladder_gb="$(ssm_last 'jq -r .limits.min_ebs_volume_size /etc/ebs-autoscale.json')"
max_gb="$(ssm_last 'jq -r .limits.max_ebs_volume_size /etc/ebs-autoscale.json')"
threshold="$(ssm_last 'jq -r .limits.initial_utilization_threshold /etc/ebs-autoscale.json')"
[[ "$ladder_gb" =~ ^[0-9]+$ && "$max_gb" =~ ^[0-9]+$ && "$threshold" =~ ^[0-9]+$ ]] \
  || die "could not read the volume sizes and threshold from /etc/ebs-autoscale.json"
[[ "$stray_count" -le 3 ]] || die "the free-space phase needs at most 3 owned volumes to keep the ${ladder_gb} GB ladder size, got ${stray_count}"
shortfall_gb=$(( (ladder_gb > max_gb ? ladder_gb : max_gb) + 1 ))
before_ids="$(owned_volumes | awk '{ printf "%s ", $1 }')" || die "could not list the owned volumes"
avail="$(ssm_last 'df -B1 --output=avail /scratch | tail -n1 | tr -d " "')"
[[ "$avail" =~ ^[0-9]+$ ]] || die "could not read the free space on /scratch (got '${avail}')"
# Ext4 keeps about 7% of a new volume, so free space sits 32 MiB under a whole GiB for one grow to clear the floor.
ssm_run "fallocate -l $(( avail % GIB + 32 * 1024 * 1024 )) /scratch/e2e.floor" >/dev/null
read -r avail pct <<<"$(ssm_last 'df -B1 --output=avail,pcent /scratch | tail -n1 | tr -d "%"')"
[[ "$avail" =~ ^[0-9]+$ && "$pct" =~ ^[0-9]+$ ]] || die "could not read /scratch after the fill (got '${avail} ${pct}')"
(( pct < threshold )) || die "utilization ${pct}% is not under the ${threshold}% threshold, so only the floor may trigger"
free_gb=$(( avail / GIB ))
floor_gb=$(( free_gb + shortfall_gb ))
ssm_run "jq --arg f ${floor_gb} --arg m $(( max_gb * 4 )) '.limits.min_free_space = \$f | .limits.max_ebs_volume_size = \$m' /etc/ebs-autoscale.json > /tmp/ebs-autoscale.json && cat /tmp/ebs-autoscale.json > /etc/ebs-autoscale.json" >/dev/null
[[ "$(ssm_last 'jq -r .limits.min_free_space /etc/ebs-autoscale.json')" == "$floor_gb" ]] \
  || die "could not set min_free_space in /etc/ebs-autoscale.json"

log "restarting the daemon with a ${floor_gb} GB floor over ${free_gb} GB free at ${pct}% utilization"
ssm_run 'systemctl start ebs-autoscale' >/dev/null
lifted=""
for ((i = 0; i < 36; i++)); do
  cur="$(ssm_last 'df -B1 --output=avail /scratch | tail -n1 | tr -d " "')"
  if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= floor_gb * GIB )); then lifted="$cur"; break; fi
  sleep 5
done
[[ -n "$lifted" ]] || die "free space on /scratch did not rise over the ${floor_gb} GB floor"
log "free space lifted to $(( lifted / GIB )) GB; waiting to confirm no extra volume is created"
sleep 20
new_vols="$(owned_volumes | awk -v before="$before_ids" \
  'BEGIN { n = split(before, ids); for (i = 1; i <= n; i++) seen[ids[i]] = 1 } NF && !($1 in seen)')" \
  || die "could not list the owned volumes"
[[ "$(printf '%s\n' "$new_vols" | awk 'NF' | wc -l | tr -d ' ')" -eq 1 ]] \
  || die "expected one new owned volume in free-space mode, got: $(printf '%s' "$new_vols" | tr '\n\t' '; ')"
new_gb="$(printf '%s\n' "$new_vols" | awk 'NF { print $2 }')"
[[ "$new_gb" == "$shortfall_gb" ]] \
  || die "expected the new volume to cover the ${shortfall_gb} GB shortfall rather than the ${ladder_gb} GB ladder size, got ${new_gb} GB"
cur="$(ssm_last 'df -B1 --output=avail /scratch | tail -n1 | tr -d " "')"
if ! [[ "$cur" =~ ^[0-9]+$ ]] || (( cur < floor_gb * GIB )); then
  die "free space on /scratch fell back under the ${floor_gb} GB floor"
fi
trigger="low disk (free=${free_gb}GB min_free=${floor_gb}GB)"
[[ "$(ssm_last "grep -cF '${trigger}' /var/log/ebs-autoscale.log || true")" -ge 1 ]] \
  || die "the daemon did not log '${trigger}'"

log "terminating and checking for leaked volumes"
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
leaked="$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:source-instance,Values=${INSTANCE_ID}" "Name=status,Values=available,in-use" \
  --query 'length(Volumes)' --output text)"
TERMINATED=1  # already terminated; keep cleanup from re-terminating
[[ "$leaked" == "0" ]] || die "$leaked autoscale volume(s) leaked after termination"

log "PASS: grew from ${initial_size}B to ${grew}B (${initial_count} -> ${final_count} volumes), folded a stray volume on restart, grew ${new_gb} GB to clear a ${floor_gb} GB floor, no leaks"
