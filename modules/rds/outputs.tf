output "endpoint" {
  value = aws_db_instance.main.endpoint
}

output "address" {
  value = aws_db_instance.main.address
}

output "port" {
  value = aws_db_instance.main.port
}

output "database_name" {
  value = aws_db_instance.main.db_name
}

output "security_group_id" {
  value = aws_security_group.rds.id
}

output "connection_url" {
  value     = local.db_connection_url
  sensitive = true
}

output "password" {
  description = "Database password (for observability postgres-exporter)"
  value       = local.db_credentials.password
  sensitive   = true
}
