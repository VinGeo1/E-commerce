output "alb_dns" {
  value = aws_lb.main.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.db.endpoint
}
