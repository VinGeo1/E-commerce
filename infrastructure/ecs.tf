# ---------------------------------------------------------------------------
# ECS on EC2: cluster, IAM, one t3.micro worker in a private subnet, and the
# backend/frontend services behind the ALB.
# ---------------------------------------------------------------------------

# --- IAM --------------------------------------------------------------------

resource "aws_iam_role" "ec2" {
  name_prefix = "ecs-worker-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ecs_service" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Lets the instance be reached through SSM Session Manager instead of a key pair
# (there is no public IP and no SSH ingress in this stack).
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs" {
  name_prefix = "ecs-worker-"
  role        = aws_iam_role.ec2.name
}

resource "aws_iam_role" "ecs_task" {
  name_prefix = "ecs-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Required: pulls the image from ECR and creates the CloudWatch log streams.
resource "aws_iam_role_policy_attachment" "ecs_task_exec" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Cluster ----------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "ecommerce-cluster"

  # Container Insights bills per metric; default metrics are enough here.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/backend"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/frontend"
  retention_in_days = 7
}

# --- Worker instances -------------------------------------------------------

resource "aws_security_group" "ecs_instance" {
  name        = "ecommerce-ecs-instance-sg"
  description = "ECS worker instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App ports from ALB"
    from_port       = 80
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The parameter store hands back the current ECS-optimised AL2023 AMI, so the
# stack never points at an AMI id that gets deprecated underneath it.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_launch_template" "ecs" {
  name_prefix   = "ecs-worker-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs.name
  }

  vpc_security_group_ids = [aws_security_group.ecs_instance.id]

  metadata_options {
    # IMDSv2 only - the task role must not be reachable over a v1 metadata GET.
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # The ECS-optimized AMI ships the agent installed and enabled, and its unit is
  # ordered After=cloud-final.service - systemd starts it only AFTER this user-data
  # script has exited. So the config written below is what the agent reads on its
  # first start, and the instance joins $ECS_CLUSTER a few minutes after boot.
  #
  # Do NOT add `systemctl start/restart ecs` here: while this script runs,
  # cloud-final is active, so a blocking start would wait for cloud-final, which
  # waits for the command to return - the script hangs (the boot's final step
  # never completes) and the agent never starts, i.e. the instance never joins
  # the cluster.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euxo pipefail
    cat > /etc/ecs/ecs.config <<'CONF'
    ECS_CLUSTER=ecommerce-cluster
    CONF
    # Non-blocking: make sure the agent unit will start at boot (it already is
    # on the optimized AMI; this covers an AMI revision that does not).
    systemctl enable ecs 2>/dev/null || systemctl enable amazon-ecs-agent 2>/dev/null || true
  EOT
  )
}

# NOTE on capacity: the account's EC2 vCPU limit is 2, i.e. exactly one t3.micro.
# min/desired are 1, and max_size 2 only matters if ECS asks for a second instance
# (which needs a vCPU limit increase, otherwise the ASG logs a cap error and the
# task stays pending).
resource "aws_autoscaling_group" "ecs" {
  name_prefix         = "ecs-worker-"
  vpc_zone_identifier = aws_subnet.private[*].id
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1

  # With health_check_type = "ELB" the ASG would replace the worker as soon as the
  # ALB marks the task unhealthy - which happens on every rollout, since host
  # networking means the new task cannot bind :8080 until the old one stops.
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # The workers have no public IP: they reach the ECS API, ECR and CloudWatch
  # Logs only through the NAT. Without this ordering the ASG could launch an
  # instance before the private routes exist; the agent would boot with no
  # egress and sit unregistered (it retries, but this avoids the "instance is
  # running, cluster is empty" window).
  depends_on = [aws_nat_gateway.nat, aws_route_table_association.private]

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  target_group_arns = [
    aws_lb_target_group.backend.arn,
    aws_lb_target_group.frontend.arn
  ]

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
}

# --- Task definitions ------------------------------------------------------
#
# network_mode = "host" (no ENI per task on EC2) and explicit portMappings, so a
# container's port is also the instance's port. That is why each service below is
# allowed to stop the old task before starting the new one.
#
# Sizing: both tasks have to fit on ONE t3.micro, which registers ~957 MiB with ECS
# (1 GiB minus what the kernel keeps). The task-level `memory` is what the scheduler
# reserves at placement, so two tasks at 512 MiB each (1024 MiB) can never both be
# placed - the second service sits at running=0 with "insufficient memory available".
# 512 (JVM) + 128 (nginx) = 640 MiB leaves ~300 MiB for the ECS agent, dockerd and
# the OS. The container `memory` is the cgroup hard limit; the backend gets the whole
# reservation because a Spring Boot 3 JVM in 256 MiB is OOM-killed (exit 137).

resource "aws_ecs_task_definition" "backend" {
  family                   = "backend"
  network_mode             = "host"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task.arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name      = "backend"
    image     = var.backend_image
    cpu       = 256
    memory    = 512
    essential = true

    portMappings = [{
      containerPort = 8080
      hostPort      = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "SPRING_DATASOURCE_URL", value = "jdbc:postgresql://${aws_db_instance.db.address}:5432/ecommerce" },
      { name = "SPRING_DATASOURCE_USERNAME", value = "dbadmin" },
      { name = "SPRING_DATASOURCE_PASSWORD", value = var.db_password }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/backend"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  depends_on = [aws_cloudwatch_log_group.backend]
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "frontend"
  network_mode             = "host"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task.arn
  cpu                      = "256"
  memory                   = "128"

  container_definitions = jsonencode([{
    name      = "frontend"
    image     = var.frontend_image
    cpu       = 256
    memory    = 128
    essential = true

    portMappings = [{
      containerPort = 80
      hostPort      = 80
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/frontend"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  depends_on = [aws_cloudwatch_log_group.frontend]
}

# --- Services --------------------------------------------------------------

resource "aws_ecs_service" "backend" {
  name            = "backend-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 1
  launch_type     = "EC2"

  # One worker + host networking: a rolling deploy needs a second free port on the
  # same instance, which it will never get. Stop-then-start instead of overlap.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Spring Boot on a t3.micro takes 60-90 s before :8080 answers, and the target
  # group then needs healthy_threshold x interval (60 s) to flip to healthy. With
  # the default grace period of 0 ECS would stop a cold-starting task as "failed
  # ELB health checks" and loop forever.
  health_check_grace_period_seconds = 180

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8080
  }

  # scripts/ecs-deploy.sh (CI) owns which task-definition revision is running.
  # Without this, every unrelated `terraform apply` would detect the service's
  # task_definition drifted from the revision Terraform registered and roll it
  # back - on this single-worker, stop-then-start setup that is an avoidable
  # outage. Terraform still updates everything else about the service.
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.ec2_ecs_service]
}

resource "aws_ecs_service" "frontend" {
  name            = "frontend-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = 1
  launch_type     = "EC2"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # nginx is up in under a second; this only covers the target group's 2 x 30 s.
  health_check_grace_period_seconds = 90

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 80
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.ec2_ecs_service]
}
