resource "aws_vpc_endpoint" "endpoint" {
  vpc_endpoint_type = var.endpoint_type
  vpc_id            = var.vpc_id
  service_name      = var.service_name
  auto_accept       = var.auto_accept
  ip_address_type   = var.ip_address_type
  tags = {
    Name = var.service_name
  }
}