variable "task_definition_family" {}
variable "task_definition_requires_compatibilities" {}
variable "task_definition_cpu" {}
variable "task_definition_memory" {}
variable "task_definition_execution_role_arn" {}
variable "task_definition_task_role_arn" {}
variable "task_definition_network_mode" {}
variable "task_definition_cpu_architecture" {}
variable "task_definition_operating_system_family" {}
variable "task_definition_container_definitions" {}

variable "service_name" {}
variable "service_cluster" {}
variable "service_launch_type" {}
variable "service_scheduling_strategy" {}
variable "service_desired_count" {}

variable "deployment_controller_type" {}

variable "load_balancer_config" {
  type = list(object({
    container_name = string
    container_port = string
    target_group_arn = string
  }))
}

variable "security_groups" {}
variable "subnets" {}
variable "assign_public_ip" {}