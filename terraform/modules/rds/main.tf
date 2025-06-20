resource "aws_db_instance" "db" {
  allocated_storage   = var.allocated_storage
  db_name             = var.db_name
  engine              = var.engine
  engine_version      = var.engine_version
  publicly_accessible = var.publicly_accessible
  multi_az            = var.multi_az
  instance_class      = var.instance_class
  username             = var.username
  password             = var.password
  max_allocated_storage = var.max_allocated_storage
  performance_insights_enabled = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  parameter_group_name = aws_db_parameter_group.parameter_group.name
  backup_retention_period = 7
  backup_window        = var.backup_window
  maintenance_window   = var.maintenance_window
  deletion_protection = var.deletion_protection
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  skip_final_snapshot  = var.skip_final_snapshot
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = var.vpc_security_group_ids
  tags = {
    Name = var.db_name
  }
}

# Subnet group for RDS
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = var.subnet_group_name
  subnet_ids = var.subnet_group_ids
  
  tags = {
    Name = var.subnet_group_name
  }
}

resource "aws_db_parameter_group" "parameter_group" {
  name   = var.parameter_group_name
  family = var.parameter_group_family

  dynamic "parameter" {
    for_each = var.parameters
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }    
  }  
}