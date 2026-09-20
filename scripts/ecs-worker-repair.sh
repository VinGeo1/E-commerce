#!/bin/sh
# ecs-worker-repair.sh - get a container instance registered again WITHOUT Terraform.
#
# For the case scripts/ecs-diagnose.sh calls verdict A1/A2: the cluster is ACTIVE but
# `aws ecs list-container-instances` is empty, so both services sit at desired=1/running=0.
# The two reasons that actually happen in this stack:
#
#   1. the worker launch template points at an AMI AWS has since retired - every
#      "InvalidAMIID.NotFound" in the ASG's scaling activities means this. (The previous
#      infrastructure/ecs.tf hardcoded ami-04fcaec208e9dd0f1, which is exactly the failure
#      the current version avoids by reading the AL2023 id from SSM Parameter Store.)
#   2. the ASG is at desired capacity 0, or holds instances that never registered because
#      their user_data named a cluster that was later deleted and recreated.
#
# It fixes both by publishing a new launch-template version with a live AMI and asking the
# ASG for one instance, then waiting for the agent to register. No Terraform state is read or
# written, which is what makes it usable while the state is missing or stale; infrastructure/
# ecs.tf uses name_prefix + ignore_changes = [image_id] on the launch template, so a later
# `terraform plan` will not fight the new AMI version.
#
#   sh scripts/ecs-worker-repair.sh          # read-only: diagnosis + plan
#   sh scripts/ecs-worker-repair.sh --yes    # execute it
#
# ECS_CLUSTER=... selects another cluster (default ecommerce-cluster).
set -u

CLUSTER="${ECS_CLUSTER:-ecommerce-cluster}"
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
ACT=0
for ARG in "$@"; do
  case "$ARG" in
    --yes|-y|yes) ACT=1 ;;
    --dry-run|--plan) ACT=0 ;;
    *) echo "note: ignoring unknown argument '$ARG'" ;;
  esac
done

FAILED=0
say() { printf '\n──────── %s ────────\n' "$1"; }
# q <args...> - read-only AWS call, tolerated
q() {
  out=$(AWS_PAGER="" aws "$@" 2>&1) || { printf '  (unavailable) %s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out"
}
# run <args...> - mutating AWS call: printed always, executed only with --yes
run() {
  printf '  $ aws %s\n' "$*"
  [ "$ACT" = "1" ] || return 0
  out=$(AWS_PAGER="" aws "$@" 2>&1) || { FAILED=1; printf '    FAILED: %s\n' "$out" >&2; return 1; }
  [ -n "$out" ] && printf '    %s\n' "$out"
  return 0
}

echo "════════════ ECS worker repair (cluster '$CLUSTER' in $REGION) ════════════"
if [ "$ACT" = "1" ]; then
  echo "mode: --yes - this WILL publish a launch template version and change ASG capacity"
else
  echo "mode: dry run - add --yes to execute"
fi
if [ "$REGION" != "us-east-1" ]; then
  echo "note: the region is '$REGION'. SSM parameter values and AMI ids are region specific, so"
  echo "      make sure this is where the stack was actually created (README uses us-east-1)."
fi

# ---------------------------------------------------------------- live AMI for this region
say "choosing a current ECS-optimised AMI"
AMI=""
AMI_PARAM=""
for PARAM in \
  /aws/service/ecs/optimized-ami/al2023/kernel-5_10/recommended/image_id \
  /aws/service/ecs/optimized-ami/al2023/recommended/image_id \
  /aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id
do
  CAND=$(q ssm get-parameters --names "$PARAM" --query 'Parameters[0].Value' --output text) || continue
  case "$CAND" in ami-*) ;; *) continue ;; esac
  if q ec2 describe-images --image-ids "$CAND" --query 'Images[0].State' --output text >/dev/null 2>&1; then
    AMI="$CAND"
    AMI_PARAM="$PARAM"
    echo "  using $AMI  (from $PARAM)"
    break
  fi
done
if [ -z "$AMI" ]; then
  cat >&2 <<EOF
  ERROR: no usable ECS-optimised AMI could be read from SSM Parameter Store.
  Terraform reads the same parameter, so if this call is blocked your IAM user is missing
  ssm:GetParameters / ec2:DescribeImages:
    aws ssm get-parameters --region $REGION \\
      --names /aws/service/ecs/optimized-ami/al2023/kernel-5_10/recommended/image_id \\
      --query 'Parameters[0].Value' --output text
EOF
  exit 1
fi

# ------------------------------------------------------ find the ASG that serves our cluster
say "scanning Auto Scaling groups for the one that joins '$CLUSTER'"
FOUND=""
FOUND_LT=""
FOUND_LTVER=""
FOUND_IMG=""
FOUND_DES=""
FOUND_MIN=""
FOUND_IDS=""
for ASG in $(q autoscaling describe-auto-scaling-groups \
               --query 'AutoScalingGroups[].AutoScalingGroupName' --output text); do
  LTID=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
            --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' --output text)
  LTVER=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
             --query 'AutoScalingGroups[0].LaunchTemplate.Version' --output text)
  MIN=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
           --query 'AutoScalingGroups[0].MinSize' --output text)
  DES=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
           --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
  MAX=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
           --query 'AutoScalingGroups[0].MaxSize' --output text)
  IDS=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
           --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text | tr '\n' ' ')
  IMG=""
  CL_OF_LT=""
  case "${LTID:-}" in
    lt-*)
      IMG=$(q ec2 describe-launch-template-versions --launch-template-id "$LTID" --versions "$LTVER" \
              --query 'LaunchTemplateVersions[0].LaunchTemplateData.ImageId' --output text)
      UD=$(q ec2 describe-launch-template-versions --launch-template-id "$LTID" --versions "$LTVER" \
              --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text)
      CL_OF_LT=$(printf '%s' "${UD:-}" | base64 -d 2>/dev/null \
                   | grep -o 'ECS_CLUSTER=[A-Za-z0-9_.-]*' | head -1 | cut -d= -f2)
      ;;
  esac
  printf '  %s\n    min/desired/max=%s/%s/%s  instances=[%s]\n    LT=%s@%s  image=%s  cluster in user_data=%s\n' \
    "$ASG" "${MIN:-?}" "${DES:-?}" "${MAX:-?}" "${IDS% }" "${LTID:-none}" "${LTVER:-?}" "${IMG:-?}" "${CL_OF_LT:-none}"

  case "${CL_OF_LT:-}" in
    "$CLUSTER")
      FOUND="$ASG"
      FOUND_LT="$LTID"
      FOUND_LTVER="$LTVER"
      FOUND_IMG="$IMG"
      FOUND_DES="$DES"
      FOUND_MIN="$MIN"
      FOUND_IDS="$IDS"
      ;;
  esac
done
if [ -z "$FOUND" ]; then
  cat >&2 <<EOF
  ERROR: no Auto Scaling group in $REGION has a launch template whose user_data joins
  '$CLUSTER', so there is no worker to repair: the capacity was never applied.

  That is the real gap here, and it is why both services are at 0 running - ECS has nothing
  to place tasks on. Either:
    1. apply infrastructure/ with Terraform state that matches this account (README step 2), or
    2. try another region:  AWS_DEFAULT_REGION=us-west-2 sh scripts/ecs-worker-repair.sh
EOF
  exit 1
fi
echo "  → repairing $FOUND"

# --------------------------------------------------------- is the current image the problem?
say "worker image health"
IMAGE_IS_BAD=0
if [ -n "${FOUND_IMG:-}" ]; then
  case "$FOUND_IMG" in
    ami-*)
      if q ec2 describe-images --image-ids "$FOUND_IMG" --query 'Images[0].State' --output text >/dev/null 2>&1; then
        echo "  current image $FOUND_IMG still resolves - the AMI is not the problem"
      else
        IMAGE_IS_BAD=1
        echo "  BAD: the launch template references $FOUND_IMG, which no longer exists in $REGION,"
        echo "       so every launch attempt fails before an instance is created."
      fi
      ;;
    *) echo "  current image: '$FOUND_IMG' (could not read it - continuing)" ;;
  esac
fi
say "recent ASG scaling activities (the real reason)"
q autoscaling describe-scaling-activities --auto-scaling-group-name "$FOUND" --max-items 4 \
  --query 'Activities[].[StatusCode,StatusMessage,Description]' --output text \
  | sed 's/^/    /' || true

# ------------------------------------------------------------------------ apply the repairs
say "plan"
if [ "$IMAGE_IS_BAD" = "1" ] || [ "${FOUND_IMG:-}" != "$AMI" ]; then
  echo "  publish $AMI as a new version of $FOUND_LT (copies instance type, SGs, instance"
  echo "  profile and user_data from the default version)"
  run ec2 create-launch-template-version \
    --launch-template-id "$FOUND_LT" --source-version '$Default' \
    --version-description ecs-worker-repair-live-AMI \
    --image-id "$AMI" || true
  if [ "$ACT" = "1" ]; then
    NEWVER=$(q ec2 describe-launch-template-versions --launch-template-id "$FOUND_LT" \
               --versions '$Latest' --query 'LaunchTemplateVersions[0].VersionNumber' --output text) || NEWVER=""
    case "${NEWVER:-}" in
      ''|*[!0-9]*) echo "  (could not read the new version number; leaving the default version alone)" ;;
      *) run ec2 modify-launch-template --launch-template-id "$FOUND_LT" --default-version "$NEWVER" ;;
    esac
  fi
  case "${FOUND_LTVER:-}" in
    *Latest*)
      echo "  the ASG follows \$Latest, so its next launch uses the new AMI by itself"
      ;;
    *)
      echo "  the ASG pins version ${FOUND_LTVER:-?} - repoint it at \$Latest"
      run autoscaling update-auto-scaling-group --auto-scaling-group-name "$FOUND" \
        --launch-template "LaunchTemplateId=$FOUND_LT,Version=\$Latest" || true
      ;;
  esac
else
  echo "  image already matches the live AMI - no launch template change needed"
fi

FOUND_IDS_COMPACT=$(printf '%s' "${FOUND_IDS:-}" | tr -d ' \t\n')
if [ -n "$FOUND_IDS_COMPACT" ]; then
  echo "  the ASG has instances but ECS lists none registered -> replace them (a fresh"
  echo "  instance re-reads user_data and re-joins the cluster)"
  for IID in $FOUND_IDS; do
    run autoscaling terminate-instance-in-auto-scaling-group \
      --auto-scaling-group-name "$FOUND" --instance-id "$IID" \
      --should-decrement-desired-capacity || true
  done
  TARGET=1
  case "${FOUND_MIN:-}" in ''|*[!0-9]*) : ;; *) [ "$FOUND_MIN" -ge 1 ] && TARGET="$FOUND_MIN" ;; esac
  echo "  then ask for the capacity back"
  run autoscaling set-desired-capacity --auto-scaling-group-name "$FOUND" --desired-capacity "$TARGET" || true
else
  TARGET=1
  case "${FOUND_MIN:-}" in ''|*[!0-9]*) : ;; *) [ "$FOUND_MIN" -ge 1 ] && TARGET="$FOUND_MIN" ;; esac
  if [ "${FOUND_DES:-0}" = "0" ]; then
    echo "  ASG is scaled to 0 - asking for $TARGET instance"
  else
    echo "  ASG has no instances at desired ${FOUND_DES:-?} - forcing a new launch"
  fi
  run autoscaling set-desired-capacity --auto-scaling-group-name "$FOUND" --desired-capacity "$TARGET" || true
fi

if [ "$FAILED" = "1" ]; then
  echo
  echo "Some calls failed - fix the error above and re-run." >&2
  exit 1
fi
if [ "$ACT" != "1" ]; then
  cat <<EOF

Dry run only. Re-run with --yes to publish the new launch template version and change the
ASG's capacity. A t3.micro is 2 vCPU, which is exactly the quota on this account, so keep
min/desired at 1 until the quota is raised (or move to t3.small + quota 4).
EOF
  exit 0
fi

# ------------------------------------------------------------------- wait for registration
WAIT_SEC=${ECS_REGISTER_TIMEOUT:-480}
say "waiting up to $(( ( WAIT_SEC + 59 ) / 60 )) min for the agent to register (ASG launch + cloud-init)"
I=0
INST=""
# ECS_REGISTER_TIMEOUT seconds, 15s per poll (default 8 min: ASG launch + cloud-init)
DEADLINE=$(( $(date +%s) + ${ECS_REGISTER_TIMEOUT:-480} ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  INST=$(q ecs list-container-instances --cluster "$CLUSTER" \
           --query 'containerInstanceArns[0]' --output text) || INST=""
  case "${INST:-}" in arn:*) break ;; esac
  sleep 15
done
case "${INST:-}" in
  arn:*) ;;
  *)
    cat >&2 <<EOF
  Still no registered container instance. These two calls say where it stopped:
    aws autoscaling describe-scaling-activities --auto-scaling-group-name $FOUND \\
      --max-items 3 --query 'Activities[].[StatusCode,StatusMessage]' --output text   # quota/AMI/SG
    aws ec2 describe-instance-status --include-all-instances \\
      --filters "Name=tag:aws:autoscaling:groupName,Values=$FOUND" \\
      --query 'InstanceStatuses[].[InstanceId,InstanceState.Name]' --output text
  If the instance is running but never registers, read the agent log over SSM (this stack has
  no SSH ingress):
    aws ssm start-session --target <i-...>
    sudo tail -n 150 /var/log/ecs/ecs-agent.log
    sudo cat /etc/ecs/ecs.config        # must say ECS_CLUSTER=$CLUSTER
EOF
    exit 1
    ;;
esac
echo "  registered: $INST"
q ecs describe-container-instances --cluster "$CLUSTER" --container-instances "$INST" \
  --query 'containerInstances[0].{Agent:agentVersion,EC2:ec2InstanceId,Status:status,Remaining:remainingResources}' \
  | sed 's/^/    /' || true

say "next"
cat <<EOF
  Capacity is back. Roll both services onto the image that is already in ECR:
    sh scripts/ecs-deploy-both.sh
  then confirm placement and target health:
    sh scripts/ecs-diagnose.sh
  infrastructure/ecs.tf keeps the AMI current on its own (data.aws_ssm_parameter.ecs_ami with
  create_before_destroy), so once your Terraform state matches this account this repair
  should not be needed again.
EOF
