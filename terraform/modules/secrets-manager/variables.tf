variable "name" {}
variable "description" {}
variable "recovery_window_in_days" {}
variable "secret_string" {}
variable "tags" {
  type = map(string)
  default = {}
}