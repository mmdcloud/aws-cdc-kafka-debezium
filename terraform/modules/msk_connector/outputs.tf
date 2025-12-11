output "connector_arn" {
  value = aws_mskconnect_connector.this.arn
}

output "connector_name" {
  value = aws_mskconnect_connector.this.name
}