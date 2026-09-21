# ---------------------------------------------------------------------------
# Application Load Balancer: /api/* -> backend service, everything else -> frontend.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "ecommerce-alb-sg"
  description = "ALB - allow HTTP from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecommerce-alb-sg" }
}

resource "aws_lb" "main" {
  name               = "ecommerce-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "ecommerce-alb" }
}

resource "aws_lb_target_group" "backend" {
  name     = "ecommerce-backend-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Give a task being replaced a moment to deregister before in-flight requests fail.
  deregistration_delay = 30

  health_check {
    path                = "/api/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    # The real application health endpoint: the app runs under the /api context
    # path (backend/src/main/resources/application.properties) and Spring Security
    # permits /actuator/health unauthenticated. The actuator health report includes
    # the database, so a target only goes "in service" once the app AND RDS answer,
    # and traffic stops again if the database drops - instead of the ALB happily
    # sending requests to a container that answers but errors on every query.
    matcher = "200"
  }
}

resource "aws_lb_target_group" "frontend" {
  name     = "ecommerce-frontend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  deregistration_delay = 30

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200,404"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "backend" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}
