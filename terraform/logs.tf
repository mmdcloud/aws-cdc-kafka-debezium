# CloudWatch Log Group for Debezium Connect
resource "aws_cloudwatch_log_group" "debezium_connect_logs" {
  name              = "/ecs/debezium-connect"
  retention_in_days = 30
}