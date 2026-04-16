output "endpoint" {
  value = aws_db_instance.db.endpoint
}

output "name" {
  value = aws_db_instance.db.db_name
}

output "db_instance_id" {
  value = aws_db_instance.db.id
}
