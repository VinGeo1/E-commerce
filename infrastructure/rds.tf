# ---------------------------------------------------------------------------
# Postgres, in the private subnets, reachable only from the ECS workers.
# ---------------------------------------------------------------------------

resource "aws_security_group" "rds" {
  name        = "ecommerce-rds-sg"
  description = "Postgres - only from the ECS worker instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_instance.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ecommerce-rds-sg" }
}

resource "aws_db_subnet_group" "main" {
  name       = "ecommerce-db-subnets"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "db" {
  identifier_prefix = "terraform-"

  engine         = "postgres"
  engine_version = "15"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  db_name           = "ecommerce"
  # "admin" and "postgres" are reserved on RDS.
  username          = "dbadmin"
  password          = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  multi_az            = false
  storage_encrypted   = true
  skip_final_snapshot = true
}
