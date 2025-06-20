resource "aws_eip" "eip" {
  domain = var.domain

  tags = {
    Name        = var.eip_name
  }
}