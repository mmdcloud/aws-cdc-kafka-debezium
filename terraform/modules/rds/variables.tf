variable "allocated_storage" {}
variable "db_name" {}
variable "engine" {}
variable "engine_version" {}
variable "publicly_accessible" {}
variable "multi_az" {}
variable "instance_class" {}
variable "username" {}
variable "password" {}
variable "parameter_group_name" {}
variable "parameter_group_family" {}
variable "parameters" {
  type = list(object({
    name  = string
    value = string
  }))
}
variable "skip_final_snapshot" {}
variable "subnet_group_name" {}
variable "subnet_group_ids" {}
variable "vpc_security_group_ids" {}
variable "backup_retention_period" {}
variable "backup_window" {}
variable "maintenance_window" {}
variable "deletion_protection" {}
variable "max_allocated_storage"{}
variable "performance_insights_enabled"{}
variable "performance_insights_retention_period"{}
variable "enabled_cloudwatch_logs_exports" {
  type = list(string)
  default = []
}