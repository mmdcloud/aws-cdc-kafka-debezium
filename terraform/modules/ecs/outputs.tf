output "name" {
  value = aws_ecs_service.carshub-service.name
}
output "task_definition_arn" {
  value = aws_ecs_task_definition.carshub_task_definition.arn
}