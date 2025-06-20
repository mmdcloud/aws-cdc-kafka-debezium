# Registering vault provider
data "vault_generic_secret" "rds" {
  path = "secret/rds"
}

# -----------------------------------------------------------------------------------------
# VPC Configuration
# -----------------------------------------------------------------------------------------
module "vpc" {
  source                = "./modules/vpc/vpc"
  vpc_name              = "cdc-vpc"
  vpc_cidr_block        = "10.0.0.0/16"
  enable_dns_hostnames  = true
  enable_dns_support    = true
  internet_gateway_name = "cdc-vpc-igw"
}

# RDS Security Group
module "rds_sg" {
  source = "./modules/vpc/security_groups"
  vpc_id = module.vpc.vpc_id
  name   = "rds-sg"
  ingress = [
    {
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      self            = "false"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
      description     = "any"
    }
  ]
  egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

# ECS Security Group
module "ecs_sg" {
  source = "./modules/vpc/security_groups"
  vpc_id = module.vpc.vpc_id
  name   = "ecs-sg"
  ingress = [
    {
      from_port       = 0
      to_port         = 0
      protocol        = "tcp"
      self            = "false"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
      description     = "any"
    }
  ]
  egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

# MSK Security Group
module "msk_sg" {
  source = "./modules/vpc/security_groups"
  vpc_id = module.vpc.vpc_id
  name   = "msk-sg"
  ingress = [
    {
      from_port       = 9092
      to_port         = 9098
      protocol        = "tcp"
      self            = "false"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
      description     = "any"
    }
  ]
  egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

# Public Subnets
module "public_subnets" {
  source = "./modules/vpc/subnets"
  name   = "public-subnet"
  subnets = [
    {
      subnet = "10.0.1.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.2.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.3.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = true
}

# Private Subnets
module "private_subnets" {
  source = "./modules/vpc/subnets"
  name   = "private-subnet"
  subnets = [
    {
      subnet = "10.0.6.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.5.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.4.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = false
}

# Public Route Table
module "public_rt" {
  source  = "./modules/vpc/route_tables"
  name    = "public-route-table"
  subnets = module.public_subnets.subnets[*]
  routes = [
    {
      cidr_block     = "0.0.0.0/0"
      gateway_id     = module.vpc.igw_id
      nat_gateway_id = ""
    }
  ]
  vpc_id = module.vpc.vpc_id
}

# Private Route Table
module "private_rt" {
  source  = "./modules/vpc/route_tables"
  name    = "private-route-table"
  subnets = module.private_subnets.subnets[*]
  routes  = []
  vpc_id  = module.vpc.vpc_id
}

# -----------------------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------------------
module "db_credentials" {
  source                  = "./modules/secrets-manager"
  name                    = "rds-secrets"
  description             = "rds-secrets"
  recovery_window_in_days = 0
  secret_string = jsonencode({
    username = tostring(data.vault_generic_secret.rds.data["username"])
    password = tostring(data.vault_generic_secret.rds.data["password"])
  })
}

# -----------------------------------------------------------------------------------------
# RDS Instance
# -----------------------------------------------------------------------------------------
module "source_db" {
  source                          = "./modules/rds"
  db_name                         = "cdcsourcedb"
  allocated_storage               = 100
  engine                          = "postgres"
  engine_version                  = "17.2"
  instance_class                  = "db.t4g.large"
  multi_az                        = true
  username                        = tostring(data.vault_generic_secret.rds.data["username"])
  password                        = tostring(data.vault_generic_secret.rds.data["password"])
  subnet_group_name               = "cdc-rds-subnet-group"
  # enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  backup_retention_period         = 7
  backup_window                   = "03:00-06:00"
  maintenance_window              = "Mon:00:00-Mon:03:00"
  subnet_group_ids = [
    module.private_subnets.subnets[0].id,
    module.private_subnets.subnets[1].id,
    module.private_subnets.subnets[2].id
  ]
  vpc_security_group_ids                = [module.rds_sg.id]
  publicly_accessible                   = false
  deletion_protection                   = false
  skip_final_snapshot                   = true
  max_allocated_storage                 = 500
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  parameter_group_name                  = "cdc-postgres17-params"
  parameter_group_family                = "postgres17"
  parameters = [
    # {
    #   name  = "wal_sender_timeout"
    #   value = "0"
    # },
    # {
    #   name  = "max_replication_slots"
    #   value = "10"
    # },
    # {
    #   name  = "max_wal_senders"
    #   value = "10"
    # },
    # {
    #   name  = "max_connections"
    #   value = "500"
    # }
  ]
}

# MSK Cluster
module "msk_cluster" {
  source                              = "./modules/msk"
  cluster_name                        = "cdc-demo-cluster"
  kafka_version                       = "2.8.1"
  number_of_broker_nodes              = 3
  instance_type                       = "kafka.m5.large"
  client_subnets                      = module.private_subnets.subnets[*].id
  security_groups                     = [module.msk_sg.id]
  ebs_volume_size                     = 100
  encryption_in_transit_client_broker = "TLS_PLAINTEXT"
  configuraion_name                   = "cdc-demo-config"
  configuraion_kafka_versions         = ["2.8.1"]
  configuraion_server_properties      = <<PROPERTIES
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
resource "aws_ecs_cluster" "debezium_cluster" {
  name = "debezium-connect-cluster"
}

# Debezium Connect ECS Configuration
module "debezium_connect_ecs" {
  source                                   = "./modules/ecs"
  task_definition_family                   = "debezium-connect"
  task_definition_requires_compatibilities = ["FARGATE"]
  task_definition_cpu                      = 2048
  task_definition_memory                   = 4096
  task_definition_execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_definition_task_role_arn            = aws_iam_role.ecs_task_execution_role.arn
  task_definition_network_mode             = "awsvpc"
  task_definition_cpu_architecture         = "X86_64"
  task_definition_operating_system_family  = "LINUX"
  task_definition_container_definitions = jsonencode(
    [
      {
        "name" : "debezium-connect",
        "image" : "debezium/connect:1.9",
        "cpu" : 1024,
        "memory" : 2048,
        "essential" : true,
        "portMappings" : [
          {
            "containerPort" : 8083,
            "hostPort" : 8083,
            "name" : "debezium_ecs_service"
          }
        ],
        "logConfiguration" : {
          "logDriver" : "awslogs",
          "options" : {
            "awslogs-group" : "/ecs/debezium-connect",
            "awslogs-region" : "us-east-1",
            "awslogs-stream-prefix" : "ecs"
          }
        },
        environment = [
          { name = "BOOTSTRAP_SERVERS", value = module.msk_cluster.bootstrap_brokers_tls },
          { name = "GROUP_ID", value = "debezium-connect-cluster" },
          { name = "CONFIG_STORAGE_TOPIC", value = "debezium-connect-configs" },
          { name = "OFFSET_STORAGE_TOPIC", value = "debezium-connect-offsets" },
          { name = "STATUS_STORAGE_TOPIC", value = "debezium-connect-status" },
          { name = "CONNECT_KEY_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
          { name = "CONNECT_VALUE_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
          { name = "CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE", value = "false" },
          { name = "CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE", value = "false" }
        ]
      }
  ])

  service_name                = "debezium_ecs_service"
  service_cluster             = aws_ecs_cluster.debezium_cluster.id
  service_launch_type         = "FARGATE"
  service_scheduling_strategy = "REPLICA"
  service_desired_count       = 1

  deployment_controller_type = "ECS"
  # load_balancer_config = [{
  #   container_name   = "debezium_ecs_service"
  #   container_port   = 3000
  #   target_group_arn = module.carshub_frontend_lb.target_groups[0].arn
  # }]

  security_groups = [module.ecs_sg.id]
  subnets = [
    module.private_subnets.subnets[0].id,
    module.private_subnets.subnets[1].id,
    module.private_subnets.subnets[2].id
  ]
  assign_public_ip = false
}

# -----------------------------------------------------------------------------------------
# IAM Roles and Policies
# -----------------------------------------------------------------------------------------
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

module "debezium_task_role" {
  source             = "./modules/iam"
  role_name          = "debezium-task-role"
  role_description   = "debezium-task-role"
  policy_name        = "debezium-task-role-policy"
  policy_description = "debezium-task-role-policy"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "ecs-tasks.amazonaws.com"
                },
                "Effect": "Allow",
                "Sid": ""
            }
        ]
    }
    EOF
  policy             = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": [
                  "kafka:GetBootstrapBrokers",
                  "kafka:DescribeCluster"
                ],
                "Resource": "*",
                "Effect": "Allow"
            }
        ]
    }
    EOF
}

# -----------------------------------------------------------------------------------------
# S3 Configuration
# -----------------------------------------------------------------------------------------

module "destination_bucket" {
  source             = "./modules/s3"
  bucket_name        = "cdcdestinationbucket"
  objects            = []
  versioning_enabled = "Enabled"
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["GET"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    },
    {
      allowed_headers = ["*"]
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  bucket_policy = ""
  force_destroy = false
  bucket_notification = {
    queue           = []
    lambda_function = []
  }
}
