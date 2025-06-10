# VPC and Networking
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "cdc-demo-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  tags = {
    Terraform   = "true"
    Environment = "demo"
  }
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "source_db" {
  identifier             = "cdc-source-db"
  instance_class         = "db.t3.medium"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "13.4"
  username               = "postgres"
  password               = var.db_password
  db_name                = "inventory"
  parameter_group_name   = aws_db_parameter_group.cdc_pg.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  multi_az               = false
  db_subnet_group_name   = aws_db_subnet_group.rds.name

  # Enable logical replication
  backup_retention_period = 7
  backup_window           = "03:00-06:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"
}

resource "aws_db_parameter_group" "cdc_pg" {
  name   = "cdc-postgres13-params"
  family = "postgres13"

  parameter {
    name  = "rds.logical_replication"
    value = "1"
  }

  parameter {
    name  = "wal_sender_timeout"
    value = "0"
  }

  parameter {
    name  = "max_replication_slots"
    value = "10"
  }

  parameter {
    name  = "max_wal_senders"
    value = "10"
  }

  parameter {
    name  = "max_connections"
    value = "500"
  }
}

resource "aws_db_subnet_group" "rds" {
  name       = "cdc-rds-subnet-group"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "CDC RDS Subnet Group"
  }
}

# MSK Cluster
resource "aws_msk_cluster" "cdc_kafka" {
  cluster_name           = "cdc-demo-cluster"
  kafka_version          = "2.8.1"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]
    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.cdc_config.arn
    revision = aws_msk_configuration.cdc_config.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
    }
  }

  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true
      }
      node_exporter {
        enabled_in_broker = true
      }
    }
  }
}

resource "aws_msk_configuration" "cdc_config" {
  kafka_versions = ["2.8.1"]
  name           = "cdc-demo-config"

  server_properties = <<PROPERTIES
auto.create.topics.enable=true
delete.topic.enable=true
log.retention.hours=168
num.io.threads=8
num.network.threads=5
num.partitions=1
num.replica.fetchers=2
replica.lag.time.max.ms=30000
socket.request.max.bytes=104857600
unclean.leader.election.enable=true
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
PROPERTIES
}

# ECS Cluster for Debezium Connect
resource "aws_ecs_cluster" "debezium" {
  name = "debezium-connect-cluster"
}

resource "aws_ecs_task_definition" "debezium_connect" {
  family                   = "debezium-connect"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.debezium_task_role.arn

  container_definitions = jsonencode([{
    name  = "debezium-connect"
    image = "debezium/connect:1.9"
    essential = true
    environment = [
      { name = "BOOTSTRAP_SERVERS", value = aws_msk_cluster.cdc_kafka.bootstrap_brokers_tls },
      { name = "GROUP_ID", value = "debezium-connect-cluster" },
      { name = "CONFIG_STORAGE_TOPIC", value = "debezium-connect-configs" },
      { name = "OFFSET_STORAGE_TOPIC", value = "debezium-connect-offsets" },
      { name = "STATUS_STORAGE_TOPIC", value = "debezium-connect-status" },
      { name = "CONNECT_KEY_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_VALUE_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE", value = "false" },
      { name = "CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE", value = "false" }
    ]
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        "awslogs-group"         = "/ecs/debezium-connect",
        "awslogs-region"        = "us-east-1",
        "awslogs-stream-prefix" = "ecs"
      }
    }
    portMappings = [{
      containerPort = 8083
      hostPort      = 8083
    }]
  }])
}

resource "aws_ecs_service" "debezium_connect" {
  name            = "debezium-connect-service"
  cluster         = aws_ecs_cluster.debezium.id
  task_definition = aws_ecs_task_definition.debezium_connect.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }
}

# Security Groups
resource "aws_security_group" "rds" {
  name        = "cdc-rds-sg"
  description = "Allow access to RDS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "msk" {
  name        = "cdc-msk-sg"
  description = "Allow access to MSK"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name        = "cdc-ecs-sg"
  description = "Allow ECS to access RDS and MSK"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Roles
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "debezium_task_role" {
  name = "debezium-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "debezium_policy" {
  name        = "debezium-policy"
  description = "Policy for Debezium to access MSK and RDS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka:GetBootstrapBrokers",
          "kafka:DescribeCluster"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "debezium_policy_attachment" {
  role       = aws_iam_role.debezium_task_role.name
  policy_arn = aws_iam_policy.debezium_policy.arn
}