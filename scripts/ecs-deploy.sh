#!/bin/sh
#
# Roll an ECS service onto a new container image by copying the task definition
# the service currently uses, swapping in the image, registering it as a new
# revision and forcing a new deployment.
#
# Required env:
#   ECS_CLUSTER     cluster name or ARN      (e.g. ecommerce-cluster)
#   ECS_SERVICE     service name or ARN      (e.g. backend-service)
#   IMAGE           full image URI to deploy (e.g. 4141...dkr.ecr.us-east-1.amazonaws.com/ecommerce-backend:<sha>)
# Optional env:
#   CONTAINER_NAME  container to re-image (defaults to the first container)
#   WAIT_FOR_STABLE set to 1 to block until the service reaches steady state
#
# Works under bash (GitHub Actions) and POSIX sh (the amazon/aws-cli image used
# by .gitlab-ci.yml), so keep this file free of shell extensions.
#
set -eu

: "${ECS_CLUSTER:?ECS_CLUSTER is required}"
: "${ECS_SERVICE:?ECS_SERVICE is required}"
: "${IMAGE:?IMAGE is required}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
WAIT_FOR_STABLE="${WAIT_FOR_STABLE:-0}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
CURRENT="$WORKDIR/current.json"
NEW="$WORKDIR/new.json"
AWS_OUT="$WORKDIR/out.txt"
AWS_ERR="$WORKDIR/err.txt"

# Failures have to be visible outside the job log: on Actions, surface them as a
# check annotation (and job summary) so tooling/CI consumers can read the reason.
annotate() {
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  # Workflow commands must stay on one line; '%' has to be escaped as %25.
  _msg=$(printf '%s' "$2" | tr -d '\r' | tr '\n' ' ' | sed 's/%/%25/g' | cut -c1-900)
  printf '::%s::%s\n' "$1" "$_msg"
}

fail() {
  echo "ERROR: $1" >&2
  annotate error "ECS deploy of $ECS_SERVICE ($ECS_CLUSTER) failed: $1"
  # Only cluster-level failures mean "the stack is gone". A missing service or a
  # wrong CONTAINER_NAME also contains "not found", so match the exact wordings
  # produced above / by the ECS API instead of that substring.
  case "$1" in
    *"cluster was inactive"*|*ClusterNotFoundException*|*"cluster '$ECS_CLUSTER' was not found"*|*"deleted or being deleted"*)
      annotate error "$ECS_CLUSTER does not exist or is being deleted: the Terraform-managed infrastructure was destroyed. Run the Terraform workflow (action=apply) to recreate it, then re-run CI."
      ;;
  esac
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    _aws_err=$(tr '\n' ' ' < "$AWS_ERR" 2>/dev/null || true)
    {
      printf '### ECS deploy failure - %s\n\n```text\n%s\n' "$ECS_SERVICE" "$1"
      [ -z "$_aws_err" ] || printf '\naws: %s\n' "$_aws_err"
      printf '```\n\n'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is not installed on this runner"
done

# aws_run <label> <aws args...>  - stdout lands in $AWS_OUT, stderr in $AWS_ERR.
aws_run() {
  _label=$1; shift
  : > "$AWS_OUT"; : > "$AWS_ERR"
  set +e
  aws "$@" > "$AWS_OUT" 2> "$AWS_ERR"
  _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    _detail=$(tr '\n' ' ' < "$AWS_ERR" | tr -s ' ' | cut -c1-700)
    [ -n "$_detail" ] || _detail=$(tr '\n' ' ' < "$AWS_OUT" | tr -s ' ' | cut -c1-700)
    fail "$_label (aws exit $_rc): $_detail"
  fi
}

# Fail before registering anything if the cluster is gone: ECS keeps deleted
# clusters around as INACTIVE, where describes still work but update-service
# throws "ClusterNotFoundException: The referenced cluster was inactive", which
# reads like a permissions bug rather than "your infrastructure was destroyed".
echo "Checking status of cluster $ECS_CLUSTER..."
aws_run "describe-clusters" ecs describe-clusters \
  --clusters "$ECS_CLUSTER" --query 'clusters[0].status' --output text
CLUSTER_STATUS=$(tr -d ' \t\n' < "$AWS_OUT")
case "$CLUSTER_STATUS" in
  ACTIVE) ;;
  "")   fail "cluster '$ECS_CLUSTER' was not found in this AWS account" ;;
  None) fail "cluster '$ECS_CLUSTER' was not found in this AWS account" ;;
  *)    fail "cluster '$ECS_CLUSTER' has status $CLUSTER_STATUS (deleted or being deleted)" ;;
esac

echo "Looking up task definition for $ECS_SERVICE in $ECS_CLUSTER..."
aws_run "describe-services" ecs describe-services \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' \
  --output text
TASK_DEF_ARN=$(tr -d ' \t\n' < "$AWS_OUT")

if [ -z "$TASK_DEF_ARN" ] || [ "$TASK_DEF_ARN" = "None" ]; then
  fail "service '$ECS_SERVICE' not found in cluster '$ECS_CLUSTER' - run the Terraform workflow (apply) first to provision the infrastructure"
fi
echo "Current task def: $TASK_DEF_ARN"

aws_run "describe-task-definition" ecs describe-task-definition \
  --task-definition "$TASK_DEF_ARN" --query 'taskDefinition' --output json

if ! jq -e 'type == "object" and (.family | type == "string")
            and (.containerDefinitions | type == "array" and length > 0)' \
  "$AWS_OUT" > /dev/null; then
  fail "unexpected describe-task-definition response; refusing to register a new revision"
fi
cp "$AWS_OUT" "$CURRENT"

if [ -n "$CONTAINER_NAME" ]; then
  if ! jq -e --arg CN "$CONTAINER_NAME" \
    '[.containerDefinitions[] | select(.name == $CN)] | length > 0' "$CURRENT" > /dev/null; then
    fail "container '$CONTAINER_NAME' not found in $TASK_DEF_ARN (containers: $(jq -r '.containerDefinitions | map(.name) | join(", ")' "$CURRENT"))"
  fi
fi

# describe-task-definition returns a superset of what RegisterTaskDefinition
# accepts (taskDefinitionArn, revision, status, requiresAttributes,
# compatibilities, registeredAt, registeredBy, deregisteredAt, tags, ...).
# Passing any of those back fails with
#   An error occurred (ParamValidation): Unknown parameter in input: "deregisteredAt"
# so instead of maintaining a blacklist of fields to delete, the payload below is
# rebuilt from an explicit allowlist of accepted arguments.
DROPPED=$(jq -r 'keys_unsorted
  - ["family", "taskRoleArn", "executionRoleArn", "networkMode", "containerDefinitions",
     "volumes", "placementConstraints", "requiresCompatibilities", "cpu", "memory", "tags",
     "pidMode", "ipcMode", "proxyConfiguration", "inferenceAccelerators", "ephemeralStorage",
     "runtimePlatform", "enableFaultInjection"]
  | join(" ")' "$CURRENT")
if [ -n "$DROPPED" ]; then
  echo "NOTE: not carried over to the new revision: $DROPPED"
fi

# runtimePlatform is valid for FARGATE tasks only; the API rejects it for EC2.
IS_EC2=$(jq -r 'if ((.requiresCompatibilities // []) | index("EC2")) != null
                then "true" else "false" end' "$CURRENT")

cat > "$WORKDIR/filter.jq" <<'JQ'
if $CN == "" then
  .containerDefinitions[0].image = $IMG
else
  .containerDefinitions |= map(if .name == $CN then .image = $IMG else . end)
end
| {
    family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
    volumes, placementConstraints, requiresCompatibilities, cpu, memory,
    pidMode, ipcMode, proxyConfiguration, inferenceAccelerators, ephemeralStorage,
    runtimePlatform: (if $IS_EC2 then null else .runtimePlatform end)
  }
| with_entries(select(.value != null and .value != [] and .value != {}))
JQ

if ! jq -c -f "$WORKDIR/filter.jq" \
  --arg IMG "$IMAGE" --arg CN "$CONTAINER_NAME" --argjson IS_EC2 "$IS_EC2" \
  "$CURRENT" > "$NEW"; then
  fail "could not build the new task definition payload"
fi

# Never register a revision that would restart the old image.
if ! jq -e --arg IMG "$IMAGE" \
  '[.containerDefinitions[].image] | index($IMG) != null' "$NEW" > /dev/null; then
  fail "image '$IMAGE' was not applied to the task definition"
fi

PAYLOAD_SUMMARY="payload for $TASK_DEF_ARN -> family=$(jq -r '.family' "$NEW") keys=$(jq -r 'keys_unsorted | join(",")' "$NEW")"
echo "$PAYLOAD_SUMMARY"
annotate notice "$PAYLOAD_SUMMARY"

echo "Registering new task definition revision for image: $IMAGE"
aws_run "register-task-definition" ecs register-task-definition \
  --cli-input-json "file://$NEW" \
  --query 'taskDefinition.taskDefinitionArn' --output text
NEW_ARN=$(tr -d ' \t\n' < "$AWS_OUT")
[ -n "$NEW_ARN" ] && [ "$NEW_ARN" != "None" ] || fail "register-task-definition returned no task definition ARN"
echo "New task def: $NEW_ARN"

aws_run "update-service" ecs update-service \
  --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$NEW_ARN" --force-new-deployment
echo "Rollout triggered for $ECS_SERVICE on $NEW_ARN"

if [ "$WAIT_FOR_STABLE" = "1" ]; then
  echo "Waiting for $ECS_SERVICE to reach steady state (up to ~10 min)..."
  set +e
  aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
  _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
      --query 'services[0].events[:10].[createdAt,message]' --output table >&2 || true
    fail "service $ECS_SERVICE did not stabilise on $NEW_ARN (see service events above)"
  fi
  echo "Service $ECS_SERVICE is stable."
fi

aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].[status,desiredCount,runningCount,taskDefinition]' --output table || true
