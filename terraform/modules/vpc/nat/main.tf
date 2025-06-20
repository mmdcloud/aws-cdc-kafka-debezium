resource "aws_eip" "eip" {
  count = length(var.subnets)  
  domain = var.domain
  tags = {
    Name = "${var.eip_name}"
  }
}

resource "aws_nat_gateway" "nat" {
  count = length(var.subnets)
  allocation_id = aws_eip.eip[count.index].id  
  subnet_id     = var.subnets[count.index].id

  tags = {
    Name = "${var.nat_gw_name}"
  }
}