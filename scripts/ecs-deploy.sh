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

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' is not installed"; exit 1; }
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
CURRENT="$WORKDIR/current.json"
NEW="$WORKDIR/new.json"

echo "Looking up task definition for $ECS_SERVICE in $ECS_CLUSTER..."
TASK_DEF_ARN=$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' \
  --output text 2>/dev/null || true)

if [ -z "$TASK_DEF_ARN" ] || [ "$TASK_DEF_ARN" = "None" ]; then
  echo "ERROR: Service '$ECS_SERVICE' or cluster '$ECS_CLUSTER' not found in AWS ECS."
  echo "Please run the Terraform workflow (apply action) first to provision the infrastructure."
  exit 1
fi
echo "Current task def: $TASK_DEF_ARN"

aws ecs describe-task-definition --task-definition "$TASK_DEF_ARN" \
  --query 'taskDefinition' --output json > "$CURRENT"

if ! jq -e 'type == "object" and (.family | type == "string")
            and (.containerDefinitions | type == "array" and length > 0)' "$CURRENT" > /dev/null; then
  echo "ERROR: unexpected describe-task-definition response; refusing to register a new revision."
  cat "$CURRENT"
  exit 1
fi

if [ -n "$CONTAINER_NAME" ]; then
  if ! jq -e --arg CN "$CONTAINER_NAME" \
    '[.containerDefinitions[] | select(.name == $CN)] | length > 0' "$CURRENT" > /dev/null; then
    echo "ERROR: container '$CONTAINER_NAME' not found in $TASK_DEF_ARN. Containers present:"
    jq -r '.containerDefinitions | map(.name) | join(", ")' "$CURRENT"
    exit 1
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

jq -c -f "$WORKDIR/filter.jq" \
  --arg IMG "$IMAGE" --arg CN "$CONTAINER_NAME" --argjson IS_EC2 "$IS_EC2" \
  "$CURRENT" > "$NEW"

# Never register a revision that would start the old image.
if ! jq -e --arg IMG "$IMAGE" \
  '[.containerDefinitions[].image] | index($IMG) != null' "$NEW" > /dev/null; then
  echo "ERROR: image '$IMAGE' was not applied to the task definition."
  jq '.containerDefinitions | map({name, image})' "$NEW"
  exit 1
fi

echo "Registering new task definition revision for image: $IMAGE"
NEW_ARN=$(aws ecs register-task-definition --cli-input-json "file://$NEW" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "New task def: $NEW_ARN"

aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$NEW_ARN" --force-new-deployment > /dev/null
echo "Rollout triggered for $ECS_SERVICE"

if [ "$WAIT_FOR_STABLE" = "1" ]; then
  echo "Waiting for $ECS_SERVICE to reach steady state (up to ~10 min)..."
  if ! aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"; then
    echo "ERROR: service $ECS_SERVICE did not stabilise. Recent service events:"
    aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
      --query 'services[0].events[:10].[createdAt,message]' --output table || true
    exit 1
  fi
  echo "Service $ECS_SERVICE is stable."
fi

aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].[status,desiredCount,runningCount,taskDefinition]' --output table || true
