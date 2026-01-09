variable "name" {
  type        = string
  description = "Name of the connector"
}
variable "kafkaconnect_version" {
  type    = string
  default = "2.7.1"
}
variable "connector_configuration" {
  type        = map(string)
  description = "Connector config map"
}
variable "bootstrap_servers" {
  type = string
}
variable "security_groups" {
  type = list(string)
}
variable "subnets" {
  type = list(string)
}
variable "authentication_type" {
  type    = string
  default = "NONE"
}
variable "encryption_type" {
  type    = string
  default = "TLS"
}
variable "plugin_arn" {
  type = string
}
variable "enable_log_delivery" {
  type    = bool
  default = false
}
variable "log_delivery" {
  type = object({
    cloudwatch_logs = object({
      enabled   = bool
      log_group = string
    })
  })
  default = {
    cloudwatch_logs = {
      enabled   = false
      log_group = ""
    }
  }
}
variable "plugin_revision" {
  type = number
}
variable "service_execution_role_arn" {
  type = string
}
# --- Capacity controls ---
variable "use_autoscaling" {
  type        = bool
  default     = true
  description = "If true uses autoscaling block, otherwise uses provisioned capacity."
}
variable "autoscaling" {
  type = object({
    worker_count     = number
    min_worker_count = number
    max_worker_count = number
    scale_in_cpu     = number
    scale_out_cpu    = number
  })

  default = {
    worker_count     = 1
    min_worker_count = 1
    max_worker_count = 2
    scale_in_cpu     = 20
    scale_out_cpu    = 80
  }
  description = "Autoscaling configuration when use_autoscaling = true"
}
variable "provisioned_worker_count" {
  type        = number
  default     = 1
  description = "Worker count when using provisioned capacity (use_autoscaling = false)"
}
# --- end capacity ---
variable "worker_count" {
  type        = number
  default     = 1
  description = "(deprecated) kept for backward compatibility"
}
