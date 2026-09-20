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

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euxo pipefail
    cat > /etc/ecs/ecs.config <<'CONF'
    ECS_CLUSTER=ecommerce-cluster
    ECS_ENABLE_CONTAINER_METADATA=true
    ECS_LOGLEVEL=info
    CONF
    systemctl enable ecs
    systemctl start ecs
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
    memory    = 256
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
  memory                   = "512"

  container_definitions = jsonencode([{
    name      = "frontend"
    image     = var.frontend_image
    cpu       = 256
    memory    = 256
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

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8080
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

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy_attachment.ec2_ecs_service]
}
