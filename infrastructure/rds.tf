resource "aws_db_subnet_group" "main" {
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "db" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "15"
  instance_class       = "db.t3.micro"
  db_subnet_group_name = aws_db_subnet_group.main.name
  username             = "dbadmin"
  password             = var.db_password
  skip_final_snapshot  = true
}
