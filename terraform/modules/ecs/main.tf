# ECS Task Definition
resource "aws_ecs_task_definition" "carshub_task_definition" {
  family                   = var.task_definition_family
  requires_compatibilities = var.task_definition_requires_compatibilities
  cpu                      = var.task_definition_cpu
  memory                   = var.task_definition_memory
  execution_role_arn       = var.task_definition_execution_role_arn
  task_role_arn            = var.task_definition_task_role_arn
  network_mode             = var.task_definition_network_mode  
  runtime_platform {
    cpu_architecture        = var.task_definition_cpu_architecture
    operating_system_family = var.task_definition_operating_system_family
  }
  container_definitions = var.task_definition_container_definitions
  tags_all = {
    Name = var.task_definition_family
  }  
}

# ECS Service
resource "aws_ecs_service" "carshub-service" {
  name                 = var.service_name
  cluster              = var.service_cluster
  task_definition      = aws_ecs_task_definition.carshub_task_definition.arn
  launch_type          = var.service_launch_type
  scheduling_strategy  = var.service_scheduling_strategy
  desired_count        = var.service_desired_count
  network_configuration {
    security_groups  = var.security_groups
    subnets          = var.subnets
    assign_public_ip = var.assign_public_ip
  }
  deployment_controller {
    type = var.deployment_controller_type
  }
  dynamic "load_balancer" {
    for_each = var.load_balancer_config
    content {
      container_name   = load_balancer.value["container_name"]
      container_port   = load_balancer.value["container_port"]
      target_group_arn = load_balancer.value["target_group_arn"]
    }
  }
  tags = {
    Name = var.service_name
  }
}
