output "name" {
  value = aws_secretsmanager_secret.secret.name
}

output "arn" {
  value = aws_secretsmanager_secret.secret.arn
}
