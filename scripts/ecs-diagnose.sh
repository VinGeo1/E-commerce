#!/bin/sh
#
# Read-only triage for "deploy succeeded, but the service has 0 running tasks".
# Covers BOTH services of this stack by default; narrow it with arguments:
#
#   sh scripts/ecs-diagnose.sh
#   sh scripts/ecs-diagnose.sh backend-service
#
# Nothing here mutates anything: it reads ECS / EC2 / Auto Scaling / ELBv2 /
# CloudWatch Logs, then prints a verdict (A: no capacity, B: image/IAM, C: unhealthy
# target, ...) with the exact next command to run.
#
set -u

CLUSTER="${ECS_CLUSTER:-ecommerce-cluster}"
SERVICES="$*"
[ -n "$SERVICES" ] || SERVICES="backend-service frontend-service"
[ -n "${AWS_DEFAULT_REGION:-}" ] || AWS_DEFAULT_REGION=$(aws configure get region 2>/dev/null || true)
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

command -v aws >/dev/null 2>&1 || { echo "ERROR: the aws CLI is required"; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
VERDICTS="$WORKDIR/verdicts.txt"
: > "$VERDICTS"

hr() { printf '\n──────── %s ────────\n' "$1"; }

verdict() {
  # $1 = code, $2 = headline, $3 = what to do
  printf '\n[%s] %s\n' "$1" "$2" >> "$VERDICTS"
  printf '%s\n' "$3" | sed 's/^/      /' >> "$VERDICTS"
}

# Run a read-only command; one missing IAM permission must not hide the rest.
try() {
  printf '\n$ aws %s\n' "$*"
  aws "$@" 2>&1 | sed 's/^/    /' | head -60
}

# text($query) -> single string, safe on failure
q() { aws ecs describe-services --cluster "$CLUSTER" --services "$1" --query "$2" --output text 2>/dev/null | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

hr "0. Who / where"
try sts get-caller-identity --output table
echo "  region=$AWS_DEFAULT_REGION  cluster=$CLUSTER  services:$SERVICES"

# ─────────────────────────────────────────────────────────────────────────────
hr "1. Cluster"
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER" \
  --query 'clusters[0].status' --output text 2>&1 | tr -d '\n')
echo "  cluster status: ${CLUSTER_STATUS:-<none>}"
case "$CLUSTER_STATUS" in
  ACTIVE) ;;
  "")
    verdict "A" "cluster '$CLUSTER' does not exist - destroyed, or never applied" \
"Recreate it (cd infrastructure && terraform init && terraform apply -auto-approve,
or Actions -> Terraform -> action=apply), then re-run CI."
    ;;
  *NotFound*|*not\ found*)
    verdict "A" "cluster '$CLUSTER' was not found: $CLUSTER_STATUS" \
"Recreate it with terraform apply, then re-run CI."
    ;;
  *)
    verdict "A" "cluster '$CLUSTER' has status '$CLUSTER_STATUS' (deleted or being deleted)" \
"ECS keeps a deleted cluster visible as INACTIVE for a while: describes answer, but
update-service fails with 'The referenced cluster was inactive'. Recreate the stack with
terraform apply, then re-run CI - the deploy will then actually place tasks."
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
hr "2. Capacity: registered container instances"
CI_COUNT=$(aws ecs list-container-instances --cluster "$CLUSTER" \
  --query 'length(containerInstanceArns)' --output text 2>&1 | tr -d '\n')
echo "  registered container instances: ${CI_COUNT:-?}"

ARNS=""
[ "$CI_COUNT" = "0" ] || ARNS=$(aws ecs list-container-instances --cluster "$CLUSTER" \
  --max-items 10 --query 'containerInstanceArns' --output text 2>&1)
if [ -n "$ARNS" ] && [ "$ARNS" != "None" ]; then
  # remainingResources is what a 256 CPU / 512 MB task is placed against.
  # shellcheck disable=SC2086
  try ecs describe-container-instances --cluster "$CLUSTER" --container-instances $ARNS \
    --query 'containerInstances[].{status:status,ec2:ec2InstanceId,agent:versionInfo.agentVersion,rCPU:remainingResources[?name==`CPU`].integerValue,rMEM:remainingResources[?name==`MEMORY`].integerValue,tasks:runningTasksCount,health:healthStatus}' \
    --output table
fi

ASG=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, 'ecs-worker-')].AutoScalingGroupName | [0]" \
  --output text 2>/dev/null | tr -d '\n')
ASG_INSTANCES=""
echo "  worker ASG: ${ASG:-<none>}"
if [ -n "$ASG" ] && [ "$ASG" != "None" ]; then
  try autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].{desired:DesiredCapacity,min:MinSize,max:MaxSize,status:Status,instances:Instances[].{id:InstanceId,life:LifecycleState,h:HealthStatus}}' \
    --output table
  # A worker that never boots says why here (vCPU quota, AMI, subnet, SG).
  try autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
    --max-items 3 --query 'ActivityDescriptions[0:3].{status:StatusCode,cause:Cause,detail:Details}' \
    --output json
  ASG_INSTANCES=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text 2>/dev/null \
    | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
fi

if [ "$CI_COUNT" = "0" ]; then
  if [ -n "$ASG_INSTANCES" ] && [ "$ASG_INSTANCES" != "None" ]; then
    # shellcheck disable=SC2086
    try ec2 describe-instances --instance-ids $ASG_INSTANCES \
      --query 'Reservations[].Instances[].{id:InstanceId,state:State.Name,ami:ImageId,type:InstanceType,launched:LaunchTime,subnet:SubnetId,sgs:SecurityGroups[].GroupId,profile:IamInstanceProfile.Arn}' \
      --output table
    verdict "A2" "an instance exists ($ASG_INSTANCES) but never registered with '$CLUSTER'" \
"Read the agent log on the box. No SSH ingress exists in this stack, so use SSM:
  aws ssm start-session --target <i-...>
  sudo tail -n 150 /var/log/ecs/ecs-agent.log
  sudo cat /etc/ecs/ecs.config          # must contain ECS_CLUSTER=$CLUSTER
Usual causes: the instance came from an older launch-template version (its user_data
named a cluster that did not exist yet), AmazonEC2ContainerServiceforEC2Role missing
from the instance profile, or the wrong region. To replace it instead of debugging it:
  sh scripts/ecs-worker-repair.sh --yes   # terminate-and-relaunch through the ASG"
  elif [ -n "$ASG" ] && [ "$ASG" != "None" ]; then
    verdict "A1" "the worker ASG ('$ASG') has no instances - nothing to place tasks on" \
"Read the scaling activities printed above first (a 2 vCPU quota with max_size=2 shows up
as 'Your requested instance count exceeds...'). Then replace the worker through the ASG.
Do NOT pick describe-instances Reservations[0].Instances[0] - that can terminate an
unrelated machine in the account:
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names '$ASG' \\
    --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text
  aws autoscaling terminate-instance-in-auto-scaling-group \\
    --auto-scaling-group-name '$ASG' --instance-id <i-...>   # desired stays 1, a replacement launches
  aws ecs wait container-instances-healthy --cluster '$CLUSTER'
If the group is at 0 and nothing is starting:
  aws autoscaling set-desired-capacity --auto-scaling-group-name '$ASG' --desired-capacity 1
Or let the repair script read the activities, repoint the launch template at a live AMI and
ask for one instance (dry run first): sh scripts/ecs-worker-repair.sh [--yes]"
  else
    verdict "A1" "no worker ASG and no container instances - the EC2 half of the stack is missing" \
"Do not apply over an empty state when the account already has the rest of the stack
(README step 2 checks exactly that). Once the state is right, terraform apply, then:
  aws autoscaling describe-auto-scaling-groups \\
    --query 'AutoScalingGroups[].[AutoScalingGroupName,DesiredCapacity]' --output table"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
for SVC in $SERVICES; do
  SHORT=${SVC%-service}

  hr "3. Service $SVC"
  try ecs describe-services --cluster "$CLUSTER" --services "$SVC" \
    --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,taskdef:taskDefinition,minHealthy:deploymentMinimumHealthyPercent,deployments:deployments[].{status:status,desired:desiredCount,running:runningCount,rollout:rolloutState},events:events[0:4].[createdAt,message]}' \
    --output json

  RUNNING=$(q "$SVC" 'services[0].runningCount')
  PENDING=$(q "$SVC" 'services[0].pendingCount')
  EVENTS=$(q "$SVC" 'services[0].events[].message')
  printf '\n  last events:\n'
  printf '%s\n' "$EVENTS" | tr ']' '\n' | grep -v '^\s*$' | head -6 | sed 's/^/    - /'

  STOPPED=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SVC" \
    --desired-status STOPPED --query 'taskArns' --output text 2>/dev/null \
    | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
  STOP_REASONS=""
  if [ -n "$STOPPED" ] && [ "$STOPPED" != "None" ]; then
    hr "4. $SHORT: stopped tasks"
    # shellcheck disable=SC2086
    try ecs describe-tasks --cluster "$CLUSTER" --tasks $STOPPED \
      --query 'tasks[].{stopped:stoppedReason,code:stopCode,startedBy:startedBy,containers:containers[].{name:name,reason:reason,exit:exitCode}}' \
      --output json
    # shellcheck disable=SC2086
    STOP_REASONS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $STOPPED \
      --query 'tasks[].stoppedReason + containers[].reason' --output text 2>/dev/null \
      | tr '\n' ' ' | tr -s ' ')
  fi

  hr "5. $SHORT: ALB target health"
  TG_STATE=""
  TG_ARN=$(aws elbv2 describe-target-groups --names "ecommerce-$SHORT-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | tr -d '\n')
  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    try elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[].{target:Target,health:TargetHealth}' --output table
    TG_STATE=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null | tr '\n' ' ')
  else
    echo "  target group ecommerce-$SHORT-tg not found - was terraform applied?"
  fi

  hr "6. $SHORT: container logs, last 15m"
  printf '$ aws logs tail /ecs/%s --since 15m\n' "$SHORT"
  aws logs tail "/ecs/$SHORT" --since 15m 2>&1 | tail -n 25 | sed 's/^/    /'

  # ---- per-service classification -------------------------------------------
  LOWER=$(printf '%s %s' "$STOP_REASONS" "$EVENTS" | tr 'A-Z' 'a-z')
  case "$LOWER" in
    *cannotpull*|*"unable to pull"*|*"repository does not exist"*|*"access denied"*)
      verdict "B" "$SHORT: the image could not be pulled" \
"Two causes, in order of likelihood:
  1. the task execution role is missing the managed policy:
       TD=\$(aws ecs describe-services --cluster $CLUSTER --services $SVC \\
             --query 'services[0].taskDefinition' --output text)
       ROLE=\$(aws ecs describe-task-definition --task-definition \"\$TD\" \\
             --query 'taskDefinition.executionRoleArn' --output text)
       aws iam list-attached-role-policies --role-name \"\$ROLE\" \\
         --query 'AttachedPolicies[].PolicyArn' --output text  # want .../AmazonECSTaskExecutionRolePolicy
     (this stack sets execution_role_arn = aws_iam_role.ecs_task.arn in ecs.tf, so a
      missing policy usually means a hand-registered revision from before that fix)
  2. the image tag is not in ECR:
       aws ecr describe-images --repository-name ecommerce-$SHORT \\
         --query 'sort_by(imageDetails,&imagePushedAt)[-3:].imageTags'
     CI tags :<git-sha> and :latest; a lifecycle policy keeps only 10 images, so an
     old sha tag can legitimately be gone - deploy :latest or a newer sha instead."
      ;;
    *oomkill*|*"exit code 137"*|*"exit code":137*)
      verdict "E" "$SHORT: container killed with exit 137 (OOM)" \
"The task's container memory is 256 MB (infrastructure/ecs.tf). Either raise it
(memory 512 with task memory 1024) or trim the JVM: JAVA_OPTS=-XX:MaxRAMPercentage=75."
      ;;
    *"unable to place a task"*|*"no container instance"*|*"insufficient cpu"*|*"insufficient memory"*|*"capacity provider"*)
      verdict "A3" "$SHORT: ECS refused to place the task (capacity, not your code)" \
"Section 2 shows the registered instances and their remaining CPU/RAM. The task asks
for 256 CPU units and 512 MB. With one t3.micro and both services deployed, the first
task of each fits; a rolling deploy needs the old task stopped first, which is what
deployment_minimum_healthy_percent = 0 is for - confirm it survived:
  aws ecs describe-services --cluster $CLUSTER --services $SVC \\
    --query 'services[0].deploymentMinimumHealthyPercent' --output text"
      ;;
  esac

  if [ "${RUNNING:-0}" = "0" ] && [ "${PENDING:-0}" != "0" ]; then
    echo "  note: pending=$PENDING with running=0 - ECS is still trying to place the task."
  fi
  if [ "${RUNNING:-0}" != "0" ] && printf '%s' "$TG_STATE" | grep -qiv healthy; then
    verdict "C" "$SHORT: task is running but the ALB target is '$TG_STATE'" \
"If it says 'initial', give the container 60-120s (Spring Boot + first DB connection).
Otherwise the port is not answering from the ALB's point of view:
  curl -sS -o /dev/null -w '%{http_code}\\n' http://<instance-private-ip>:8080/api/actuator/health
  aws ec2 describe-security-groups --group-ids <ecs-instance-sg>   # must allow 80,8080 from the ALB SG
The backend target group checks /actuator/health but the app serves it under /api, so a
404 is expected and accepted (matcher 200,401,404 in infrastructure/alb.tf)."
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
hr "Verdicts"
if [ -s "$VERDICTS" ]; then
  sed 's/^/  /' "$VERDICTS"
else
  cat <<'EOF'
  No capacity, placement, image or target-health problem detected. If a service still
  shows running=0, compare its deployments[] rolloutState with the events printed in
  section 3 - a stuck REPLACEMENT deployment with the old PRIMARY still running means
  deployment_minimum_healthy_percent is back to 100 (host networking + one instance
  can never satisfy that).
EOF
fi

printf '\n──────── next: after the worker registers, roll both services ────────\n'
printf '  REGISTRY=%s.dkr.ecr.%s.amazonaws.com TAG=<git-sha> sh scripts/ecs-deploy-both.sh\n' \
  "${AWS_ACCOUNT_ID:-414100287492}" "$AWS_DEFAULT_REGION"
