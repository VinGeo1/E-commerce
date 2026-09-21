# E-Commerce on AWS ECS (EC2 launch type)

A small e-commerce app — Java 17 / Spring Boot 3.3 API and a React 18 frontend — packaged as two
Docker images, stored in ECR, and run as ECS services on EC2 worker instances behind an
Application Load Balancer, with Postgres on RDS. Everything on AWS is described in Terraform, and
GitHub Actions is the only deploy path: push to `main` → images are built and pushed → both ECS
services are rolled onto the new image tags. Terraform is applied or destroyed from the Actions UI
against one shared S3 state file.

## Architecture

```
                        ┌─────────────── public subnet ×2 ───────────────┐
  browser ──HTTP:80──►  │            ALB  ecommerce-alb                  │
                        │   /            → ecommerce-frontend-tg :80     │
                        │   /api/*       → ecommerce-backend-tg  :8080   │
                        └───────────┬────────────────────────────────────┘
                                    │  (target group health checks)
      ┌───────────────── private subnet ×2 ─────────────────┐
      │  EC2 t3.micro worker (ASG min/desired 1, max 2)     │
      │    ├─ frontend container   :80   (nginx, host net)  │
      │    └─ backend  container   :8080 (Spring Boot)      │
      │  RDS Postgres 15  db.t3.micro   :5432               │
      └─────────────────────────────────────────────────────┘
      images pulled from ECR (ecommerce-backend, ecommerce-frontend)
      stdout → CloudWatch Logs /ecs/backend, /ecs/frontend
```

`network_mode = "host"`: containers use the instance's ports directly, so `80`/`8080` are the
only ports the ALB security group needs to reach. The two ECS services are allowed to stop the old
task before starting the new one (`deployment_minimum_healthy_percent = 0`) because a second task
on the same instance could never bind the same host port.

## Tech stack

| Layer | Choice |
|---|---|
| Backend | Java 17, Spring Boot 3.3.0, Spring Web / Security / Data JPA / Validation / Actuator, JJWT |
| Frontend | React 18, Create React App (`react-scripts` 5), `axios`, `react-router-dom` |
| Database | Amazon RDS for PostgreSQL 15 (`db.t3.micro`, 20 GB) |
| Infra | Terraform ≥ 1.5, AWS provider `~> 5.0`, S3 + DynamoDB state backend |
| Compute | ECS (EC2 launch type) on an ECS-optimized AL2023 AMI via Auto Scaling |
| Traffic | Application Load Balancer, HTTP only (no ACM cert in this scope) |
| CI/CD | GitHub Actions: `ci.yml` (build → ECR → deploy), `terraform.yml` (plan/apply/destroy) |

## Repo layout

```
.github/workflows/ci.yml            build + push + ECS rollout
.github/workflows/terraform.yml     manual plan / apply / destroy
backend/                            Spring Boot API (see Deliverable 1)
frontend/                           React app served by nginx (see Deliverable 2)
infrastructure/                     Terraform: vpc, ecr, alb, ecs, rds, backend.tf
scripts/ecs-deploy.sh               the deploy step used by both CI jobs
```

## AWS account context

Assumed while writing this repo: account `414100287492`, region `us-east-1`, EC2 vCPU quota of
**2** (one `t3.micro` at a time), and a $200 promotional credit. The quota is why the ASG is
`desired = 1`, and why `max = 2` is only useful after a quota increase.

## Prerequisites

- AWS account with permissions for VPC/EC2/ECS/ELBv2/RDS/ECR/IAM/CloudWatch Logs/S3/DynamoDB
- Terraform >= 1.5, Docker, Git, AWS CLI v2 (`aws --version`)
- A GitHub repository with Actions enabled

## Setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd ecommerce
```

### 2. Terraform state bucket (one time)

`infrastructure/backend.tf` already points at `ecommerce-tfstate-414100287492`, so the bucket and
its lock table must exist before the first `terraform init` — locally *and* in Actions:

```bash
export AWS_DEFAULT_REGION=us-east-1

# us-east-1 rejects a LocationConstraint, so only --region is passed
aws s3api create-bucket --bucket ecommerce-tfstate-414100287492 --region us-east-1
aws s3api put-bucket-versioning --bucket ecommerce-tfstate-414100287492 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket ecommerce-tfstate-414100287492 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket ecommerce-tfstate-414100287492 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name ecommerce-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

aws dynamodb describe-table --table-name ecommerce-tfstate-lock --query 'Table.TableStatus' --output text   # ACTIVE
```


Attach this to the identity that runs Terraform (and to the CI access key) if it is not an admin:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::ecommerce-tfstate-414100287492",
        "arn:aws:s3:::ecommerce-tfstate-414100287492/*"
      ]
    },
    {
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:414100287492:table/ecommerce-tfstate-lock"
    }
  ]
}
```

An **empty bucket is normal before the first apply** - it is only a problem if the bucket has no
`prod/terraform.tfstate` *while the account already has the resources*. That mismatch is what
happens when an earlier run had no backend: `terraform init` on a GitHub runner with no
`backend.tf` keeps its state on the ephemeral machine, so every apply created real resources
and threw the state away. `infrastructure/cleanup.sh` (and the hardcoded VPC ids inside it)
exists in this repo's history for exactly that reason.

Before applying anything, check what the state thinks versus what exists:

```bash
aws ec2 describe-vpcs --filters Name=tag:Project,Values=ecommerce \
  --query 'VPCs[].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output text
aws ecs describe-clusters --clusters ecommerce-cluster --query 'clusters[0].status' --output text
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[].[AutoScalingGroupName,MinSize,DesiredCapacity,MaxSize]' --output text
```

If resources exist and the state is empty, do **not** run `terraform apply`: it would build a
second VPC, NAT gateway (~$33/month each) and RDS instance next to the first. Either recover the
previous `terraform.tfstate` and `terraform init -migrate-state`, or delete the leftovers first.
For the worker/capacity half of the problem there is also a state-free repair:
`sh scripts/ecs-worker-repair.sh` (below).

### 3. ECR repositories

Nothing to do: `infrastructure/ecr.tf` creates `ecommerce-backend` and `ecommerce-frontend` with a
"keep last 10 images" lifecycle policy. Do **not** also run `aws ecr create-repository` — Terraform
would fail with `RepositoryAlreadyExistsException`. (Only if you deliberately keep ECR out of
Terraform: `aws ecr create-repository --repository-name ecommerce-backend` and
`--repository-name ecommerce-frontend`.)

### 4. IAM user for CI

Create an access key for a user that can push to ECR and roll ECS services. For a throwaway
learning account, `AdministratorAccess` is the fast path; the scoped set is
`EC2ContainerRegistryPowerUser` plus `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`,
`ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `ecs:DescribeClusters` — and the state policy
from step 2.

### 5. Configure GitHub

Settings → **Secrets and variables → Actions**:

| Secrets | |
|---|---|
| `AWS_ACCESS_KEY_ID` | from step 4 |
| `AWS_SECRET_ACCESS_KEY` | from step 4 |
| `DB_PASSWORD` | the RDS password; the Terraform workflow falls back to this secret |

| Repository variables | |
|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` |
| `AWS_ACCOUNT_ID` | `414100287492` |
| `ALB_DNS` | fill in after step 6 (frontend container URL for external use; the ALB already routes `/api`) |

### 6. Apply the infrastructure

From your laptop:

```bash
cd infrastructure
echo 'db_password = "MyApp2025!SecurePass"' > terraform.tfvars   # gitignored, >= 8 chars
terraform init            # attaches the S3 backend from step 2
terraform plan
terraform apply
terraform output -raw alb_dns    # → put it in the ALB_DNS variable
```

Or from GitHub: **Actions → Terraform → Run workflow → `action: apply`** (leave `db_password`
empty if the `DB_PASSWORD` secret is set; `action: destroy` additionally requires typing
`DESTROY`). Runs are serialised through `concurrency` + the DynamoDB lock, and take ~8-10 min
because the NAT gateway and RDS are slow.

### 7. Push to main

```bash
git push origin main
```

CI builds both images, pushes `:<git-sha>` and `:latest` to ECR, and rolls `backend-service` and
`frontend-service`. Watch it in **Actions → CI**; a failed deploy prints the AWS error as an
annotation on the job (no need to open the raw log).

### 8. Smoke test

```bash
ALB=$(cd infrastructure && terraform output -raw alb_dns)
curl -i http://$ALB/                     # 200 - React shell
curl -i http://$ALB/api/products          # 200 - [] on a fresh stack
curl -s -XPOST http://$ALB/api/auth/signup -H 'content-type: application/json' \
  -d '{"email":"seller@example.com","password":"supersecret1","role":"SELLER"}'
TOKEN=$(curl -s -XPOST http://$ALB/api/auth/signin -H 'content-type: application/json' \
  -d '{"email":"seller@example.com","password":"supersecret1"}' | sed 's/.*"token":"\([^"]*\)".*/\1/')
curl -s -XPOST http://$ALB/api/products -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"name":"Headphones","price":49.99}'
curl -s http://$ALB/api/products         # → the product is listed
```

### 9. If the services never reach `running`

The worker instance needs ~3-4 minutes after `apply` before the ECS agent registers. Then:

```bash
sleep 240
aws ecs list-container-instances --cluster ecommerce-cluster
aws ecs update-service --cluster ecommerce-cluster --service backend-service  --force-new-deployment
aws ecs update-service --cluster ecommerce-cluster --service frontend-service --force-new-deployment
```

## API surface

| Method | Path | Auth | Notes |
|---|---|---|---|
| `POST` | `/api/auth/signup` | public | `{email, password, role?}` → `201 {id, email, role}`; role defaults to `BUYER` |
| `POST` | `/api/auth/signin` | public | `{email, password}` → `{token, tokenType, id, email, role}` |
| `GET` | `/api/products` | public | catalogue for the buyer page |
| `POST` | `/api/products` | `SELLER` | `{name, price}`; `sellerId` is taken from the JWT, never the body |
| `PUT` | `/api/products/{id}` | `SELLER` | updates `price` (and `name` if sent); only the owning seller |
| `POST` | `/api/auth/otp/*`, `/api/auth/google` | public | **stubs** returning `501` — see the `TODO(auth)` comments |

Datasource settings come from `SPRING_DATASOURCE_URL` / `_USERNAME` / `_PASSWORD`, which
`infrastructure/ecs.tf` injects into the task definition.

## Deployment flow

1. `validate` — checks the secrets/variables exist, fails early with a named list.
2. `build-and-push-backend` / `build-and-push-frontend` — ECR login, `docker/build-push-action@v5`,
   tags `:<github.sha>` **and** `:latest`.
3. `deploy-backend` / `deploy-frontend` (main pushes and manual runs) — `scripts/ecs-deploy.sh`:
   checks the cluster is `ACTIVE`, reads the service's current task definition, swaps the container
   image, registers a new revision from **only the arguments `RegisterTaskDefinition` accepts**, and
   calls `update-service --force-new-deployment`. Set `WAIT_FOR_STABLE: 1` on a job to also wait for
   steady state.

## Cost estimate

| Item | ~Monthly |
|---|---|
| NAT Gateway (365-day-visible cost driver) | $32.85 |
| ALB | $16.43 |
| EC2 `t3.micro` worker | $7.60 after the 750 h free tier |
| RDS `db.t3.micro` + 20 GB | $14.71 |
| ECR + CloudWatch Logs | ~$1.00 |
| S3 state bucket + DynamoDB lock | ~$0.10 |
| **Total** | **~$74** |

On a $200 credit that is roughly **2.5 months** — so destroy the stack when you are done (below).
Drop the NAT gateway + private subnets (put the workers in public subnets) to save ~$33/month.

## How to destroy

**Actions → Terraform → Run workflow → `action: destroy`**, and type `DESTROY` in `confirmation`.
The workflow refuses without it. Local equivalent:

```bash
cd infrastructure && terraform destroy -var-file=terraform.tfvars
```

Destroying removes the cluster too, so the next CI deploy fails with
`cluster 'ecommerce-cluster' was not found / has status INACTIVE` until you apply again — the
`ecs-deploy.sh` preflight prints exactly that.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Deploy "succeeds" but `runningCount` is 0 | no capacity / image pull / port not answering | `sh scripts/ecs-diagnose.sh` (read-only) - see below |
| `list-container-instances` is empty, ASG activity says `InvalidAMIID.NotFound` | the worker launch template points at a retired AMI, or the ASG is scaled to 0 | `sh scripts/ecs-worker-repair.sh` then the same with `--yes` |
| `502 Bad Gateway` from the ALB | task not running, or the SG does not allow the ALB → instance on 80/8080 | `aws ecs describe-services --cluster ecommerce-cluster --services backend-service`; check `aws ecs describe-tasks` `stoppedReason` |
| `503 Service Unavailable` | target registered but unhealthy | health-check path/`matcher` in `alb.tf`; backend answers 404 on `/actuator/health` (context path `/api`) which is accepted |
| Timeouts on first requests | Spring Boot cold start + RDS connection | raise `unhealthy_threshold`/`interval` on the backend target group, or warm up before testing |
| No targets registered at all | ECS agent never joined the cluster | wait 3-4 min after apply, then `aws ecs list-container-instances`; check the instance's `/var/log/ecs/ecs-agent.log` (SSM Session Manager → `mysql`-free AL2023 host) |
| Deploy fails: `Unknown parameter in input: "deregisteredAt"` | task definition JSON from `describe-task-definition` replayed verbatim | already handled — `scripts/ecs-deploy.sh` rebuilds the payload from the accepted arguments and logs what it drops |
| Deploy fails: `The referenced cluster was inactive` | the stack was destroyed | `terraform apply` again (Actions → Terraform), then re-run CI |
| Deploy fails: `Capacity providers ... no container instances` / task stuck in `PENDING` | ASG instance still booting, or the 2-vCPU quota already used by a second instance | `aws autoscaling describe-auto-scaling-groups`; check `STOPPED_REASON` of the failed task |
| `terraform init` error about the S3 backend | bucket/lock table missing, or the key lacks the state policy | re-run setup step 2 |
| `Error acquiring the state lock` | concurrent run, or a crashed run left a row | wait, or delete the row: `aws dynamodb delete-item --table-name ecommerce-tfstate-lock --key '{"LockID":{"S":"ecommerce-tfstate-414100287492/prod/terraform.tfstate"}}'` |
| `CannotPullContainerImage` | ECR repos empty (never pushed) or wrong account in the image URI | push once via CI, or set `TF_VAR_backend_image`/`TF_VAR_frontend_image` |

### Triage: "deploy succeeded" but 0 running tasks

`update-service` returning without an error only means ECS accepted the new revision - the
task still has to be placed on a registered instance and pass the target group health check.
CI therefore sets `WAIT_FOR_STABLE: 1` on both deploy jobs (the job fails unless the service
reaches steady state) and runs the triage script automatically afterwards. Reproduce it by hand:

```bash
sh scripts/ecs-diagnose.sh                      # both services
sh scripts/ecs-diagnose.sh backend-service      # one of them
```

It reads (never writes) the cluster status, registered container instances and their remaining
CPU/RAM, the worker ASG plus its **scaling activities** (where a vCPU-quota or AMI failure
shows up), each service's `deployments[]`/events, stopped-task `stoppedReason`s, ALB target
health and the last 15 minutes of container logs - then prints a verdict:

| Verdict | Meaning | Next step it prints |
|---|---|---|
| `A`  | cluster missing or `INACTIVE` | `terraform apply`, then re-run CI |
| `A1` | worker ASG has no instances | read scaling activities; `set-desired-capacity` |
| `A2` | instance exists but never registered | SSM Session Manager → `tail /var/log/ecs/ecs-agent.log`, `cat /etc/ecs/ecs.config` |
| `A3` | "unable to place a task ... insufficient CPU/memory" | compare task CPU/RAM with `remainingResources`; check `deploymentMinimumHealthyPercent` |
| `B`  | `CannotPullContainerError` / access denied | task execution role policy, or the tag is gone from ECR (lifecycle keeps 10 images) |
| `C`  | task running, target unhealthy | 60-120s cold start, then SG/path check (backend health is `/api/actuator/health`) |
| `E`  | exit 137 / OOM | the backend container's hard limit is 512 MiB in `ecs.tf` (JVM heap capped at 50% via `JAVA_TOOL_OPTIONS` in `backend/Dockerfile`) |

For verdicts `A1`/`A2` - no registered worker - there is a repair path that does not need
Terraform state at all. It is dry-run first, and it only ever touches the ASG whose launch
template `user_data` joins your cluster:

```bash
sh scripts/ecs-worker-repair.sh          # prints the ASG, its AMI, the scaling activities, the plan
sh scripts/ecs-worker-repair.sh --yes    # publishes a launch template version with a live
                                         # AL2023 ECS AMI, asks for 1 instance, waits for registration
```

Read the plan before adding `--yes`. `ECS_REGISTER_TIMEOUT` (seconds, default 480) bounds the
wait for the agent to come back, and it fails with the exact SSM / scaling-activity commands to
run if the instance boots but never registers.

To roll **both** services onto the same tag once capacity is back (the CI jobs do this in
parallel; this is the sequential, single-command version - it runs the triage itself if a
service fails to converge):

```bash
REGISTRY=414100287492.dkr.ecr.us-east-1.amazonaws.com TAG=$(git rev-parse HEAD) \
  sh scripts/ecs-deploy-both.sh          # TAG=latest also works; both services, backend first
```

### Recycling a stuck worker safely

If the instance must be replaced, go through the Auto Scaling group so a replacement is
launched and the ASG stays consistent:

```bash
ASG=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, 'ecs-worker-')].AutoScalingGroupName | [0]" \
  --output text)
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text
aws autoscaling terminate-instance-in-auto-scaling-group \
  --auto-scaling-group-name "$ASG" --instance-id <i-...>       # desired stays 1 -> replacement launches
aws ecs wait container-instances-healthy --cluster ecommerce-cluster
```

Do **not** use `aws ec2 describe-instances --query 'Reservations[0].Instances[0].InstanceId'`
to pick a victim: that is the first running instance in the whole account, not this stack's
worker, and with `min_size = 1` a bare `ec2 terminate-instances` leaves the ASG to notice it
later. The ASG-scoped call above is immediate and instance-level.

### Running it locally

```bash
# API (needs a reachable Postgres, e.g. docker run -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=ecommerce -p 5432:5432 postgres:15)
cd backend && mvn spring-boot:run        # http://localhost:8080/api/products

# Frontend (proxies nothing: set the API origin explicitly)
cd frontend && REACT_APP_API_URL=http://localhost:8080/api npm start
```

`frontend/Dockerfile` bakes `REACT_APP_API_URL` at build time (default empty → same-origin `/api`,
which is what the ALB routing needs).

### Images

```bash
docker build -t ecommerce-backend:dev backend/
docker build -t ecommerce-frontend:dev frontend/
```

## Notes on what is intentionally not here

- OTP and Google OAuth are stubs returning `501`; passwords are BCrypt, JWTs are HS256 with a
  dev secret in `application.properties` (override `JWT_SECRET` in the task definition).
- No HTTPS/ACM certificate, no WAF, no secrets manager: HTTP on port 80 is the whole listener.
- `Order` has an entity and repository but no checkout controller — the "Buy" button says so.
- No automated tests in CI; `mvn -DskipTests` in the Docker build keeps the image build fast.
