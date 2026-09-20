output "alb_dns" {
  description = "Put this in the ALB_DNS GitHub repository variable; it is the app URL."
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "host:port of the Postgres instance (private subnet - reachable from the ECS workers only)."
  value       = aws_db_instance.db.endpoint
}
