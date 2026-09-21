#!/bin/sh
#
# Roll BOTH services of this stack onto one image tag, so backend and frontend
# always move together (the CI workflow runs them as parallel jobs instead).
#
#   REGISTRY=414100287492.dkr.ecr.us-east-1.amazonaws.com TAG=$(git rev-parse HEAD) \
#     sh scripts/ecs-deploy-both.sh
#
#   TAG=latest sh scripts/ecs-deploy-both.sh frontend-service     # one service only
#
# Env:
#   REGISTRY  ECR registry host (defaults from AWS_ACCOUNT_ID/AWS_DEFAULT_REGION)
#   TAG       image tag to deploy (default: latest)
#   IMAGES    optional explicit list, overriding REGISTRY/TAG, e.g.
#             "backend-service=....amazonaws.com/ecommerce-backend:abc frontend-service=..."
#   WAIT_FOR_STABLE  1 to wait for each service to reach steady state (default 1)
#
set -eu

HERE=$(dirname "$0")
CLUSTER="${ECS_CLUSTER:-ecommerce-cluster}"
REGISTRY="${REGISTRY:-${AWS_ACCOUNT_ID:-414100287492}.dkr.ecr.${AWS_DEFAULT_REGION:-us-east-1}.amazonaws.com}"
TAG="${TAG:-latest}"
WAIT_FOR_STABLE="${WAIT_FOR_STABLE:-1}"
SERVICES="${1:-backend-service frontend-service}"

FAILED=""
ROLLOUTS=0
for SVC in $SERVICES; do
  ROLLOUTS=$(( ROLLOUTS + 1 ))
  SHORT=${SVC%-service}
  IMAGE=""
  for ENTRY in ${IMAGES:-}; do
    case "$ENTRY" in
      "$SVC="*) IMAGE=${ENTRY#*=} ;;
    esac
  done
  [ -n "$IMAGE" ] || IMAGE="$REGISTRY/ecommerce-$SHORT:$TAG"

  printf '\n════════════ %s -> %s ════════════\n' "$SVC" "$IMAGE"
  if ECS_CLUSTER="$CLUSTER" ECS_SERVICE="$SVC" CONTAINER_NAME="$SHORT" \
     IMAGE="$IMAGE" WAIT_FOR_STABLE="$WAIT_FOR_STABLE" sh "$HERE/ecs-deploy.sh"; then
    echo "OK: $SVC"
  else
    echo "FAILED: $SVC" >&2
    FAILED="$FAILED $SVC"
  fi
done

if [ -n "$FAILED" ]; then
  echo
  echo "Deploy did not converge for:$FAILED" >&2
  echo "Running read-only triage (cluster capacity / stopped tasks / target health):" >&2
  # shellcheck disable=SC2086  # $FAILED is a space-separated list of service names
  ECS_CLUSTER="$CLUSTER" sh "$HERE/ecs-diagnose.sh" $FAILED || true
  exit 1
fi
echo
echo "$ROLLOUTS service(s) rolled out and stable (WAIT_FOR_STABLE=$WAIT_FOR_STABLE)."
