resource "aws_instance" "instance" {
  ami                         = var.ami
  instance_type               = var.instance_type
  associate_public_ip_address = var.associate_public_ip_address  
  key_name        = var.key_name
  subnet_id       = var.subnet_id
  security_groups = var.security_groups
  user_data       = var.user_data
  tags = {
    Name = var.name
  }
}