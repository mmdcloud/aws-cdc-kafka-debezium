variable "dimensions" {}
variable "alarm_name"{}
variable "comparison_operator"{}
variable "evaluation_periods"{}
variable "metric_name"{}
variable "namespace"{}
variable "period"{}
variable "statistic"{
    default = ""
}
variable "threshold"{}
variable "alarm_description"{}
variable "alarm_actions"{}
variable "ok_actions"{}
variable "extended_statistic" {
    default = ""
}
variable "treat_missing_data" {
    type        = string
    default = "missing"
    validation {
    condition     = contains(["breaching", "ignore", "missing", "notBreaching"], var.treat_missing_data)
    error_message = "The treat_missing_data value must be one of: breaching, ignore, missing, or notBreaching."
  }
}