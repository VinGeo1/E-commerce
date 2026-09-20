resource "aws_lb" "main" {
  subnets            = slice(aws_subnet.public[*].id, 0, 2)
  load_balancer_type = "application"
  internal           = false
}

resource "aws_lb_target_group" "backend" {
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_target_group" "frontend" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
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
