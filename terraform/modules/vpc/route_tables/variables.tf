variable "routes" {
  type = list(object({
    cidr_block = string
    gateway_id = string
    nat_gateway_id = string
  }))
}
variable "vpc_id" {}
variable "name" {}
variable "subnets" {}
