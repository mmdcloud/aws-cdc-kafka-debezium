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
  source            = "./modules/rds"
  db_name           = "cdcsourcedb"
  allocated_storage = 100
  engine            = "postgres"
  engine_version    = "17.2"
  instance_class    = "db.t4g.large"
  multi_az          = true
  username          = tostring(data.vault_generic_secret.rds.data["username"])
  password          = tostring(data.vault_generic_secret.rds.data["password"])
  subnet_group_name = "cdc-rds-subnet-group"
  # enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  backup_retention_period = 7
  backup_window           = "03:00-06:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"
  subnet_group_ids = [
    module.public_subnets.subnets[0].id,
    module.public_subnets.subnets[1].id,
    module.public_subnets.subnets[2].id
  ]
  vpc_security_group_ids                = [module.rds_sg.id]
  publicly_accessible                   = true
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
  client_subnets                      = module.public_subnets.subnets[*].id
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

module "plugins_bucket" {
  source      = "./modules/s3"
  bucket_name = "cdcdebeziumplugins"
  objects = [
    {
      key    = "debezium-postgres-connector.zip"
      source = "../connectors/debezium-postgres-connector.zip"
    },
    {
      key    = "s3-sink.zip"
      source = "../connectors/s3-sink.zip"
    }
  ]
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

# MSK Connect Custom Plugin - Debezium source connector
resource "aws_mskconnect_custom_plugin" "debezium_postgres_plugin" {
  name         = "debezium-postgres-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = module.destination_bucket.arn
      file_key   = "debezium-postgres-connector.zip"
    }
  }
}

# MSK Connect Custom Plugin - S3 sink connector
resource "aws_mskconnect_custom_plugin" "s3_sink_plugin" {
  name         = "s3-sink-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = module.destination_bucket.arn
      file_key   = "s3-sink.zip"
    }
  }
}

resource "aws_iam_role" "debezium_connector_role" {
  name = "debezium-connector-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "kafkaconnect.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "debezium_connector_policy" {
  name        = "debezium-connector-policy"
  description = "Policy for Debezium connector service execution role"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "kafka:DescribeCluster",
          "kafka:DescribeTopic",
          "kafka:GetBootstrapBrokers",
          "kafka:CreateTopic",
          "kafka:DeleteTopic",
          "kafka:DescribeGroup",
          "kafka:ListGroups",
          "kafka:AlterCluster",
          "kafka:AlterGroup",
          "kafka:Connect",
          "kafka:ReadData",
          "kafka:WriteData"
        ],
        Resource = "${module.msk_cluster.arn}"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue"
        ],
        Resource = "*" # Restrict this to your secrets ARN if using Secrets Manager
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_debezium_connector_policy" {
  role       = aws_iam_role.debezium_connector_role.name
  policy_arn = aws_iam_policy.debezium_connector_policy.arn
}

resource "aws_iam_role" "s3_sink_role" {
  name = "s3-sink-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "kafkaconnect.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "s3_sink_policy" {
  name        = "s3-sink-policy"
  description = "Policy for S3 sink connector service execution role"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "kafka:DescribeCluster",
          "kafka:DescribeTopic",
          "kafka:GetBootstrapBrokers",
          "kafka:CreateTopic",
          "kafka:DeleteTopic",
          "kafka:DescribeGroup",
          "kafka:ListGroups",
          "kafka:AlterCluster",
          "kafka:AlterGroup",
          "kafka:Connect",
          "kafka:ReadData",
          "kafka:WriteData"
        ],
        Resource = "${module.msk_cluster.arn}"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation"
        ],
        Resource = [
          "${module.destination_bucket.arn}",
          "${module.destination_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_s3_sink_policy" {
  role       = aws_iam_role.s3_sink_role.name
  policy_arn = aws_iam_policy.s3_sink_policy.arn
}


resource "aws_mskconnect_connector" "debezium_postgres_connector" {
  name = "debezium-postgres-connector"

  kafkaconnect_version = "2.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class"   = "io.debezium.connector.postgresql.PostgresConnector"
    "database.hostname" = "${module.source_db.endpoint}"
    "database.port"     = 5432
    "plugin.name"       = "pgoutput"
    "slot.name"         = "debezium"
    "publication.name"  = "debezium_pub"
    "database.user"     = tostring(data.vault_generic_secret.rds.data["username"])
    "database.password" = tostring(data.vault_generic_secret.rds.data["password"])
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls

      vpc {
        security_groups = [aws_security_group.example.id]
        subnets = [
          module.public_subnets.subnets[0].id,
          module.public_subnets.subnets[1].id,
          module.public_subnets.subnets[2].id
        ]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium_postgres_plugin.arn
      revision = aws_mskconnect_custom_plugin.debezium_postgres_plugin.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.debezium_connector_role.arn
}

resource "aws_mskconnect_connector" "s3_sink_connector" {
  name = "s3-sink-connector"

  kafkaconnect_version = "2.7.1"

  capacity {
    autoscaling {
      mcu_count        = 1
      min_worker_count = 1
      max_worker_count = 2

      scale_in_policy {
        cpu_utilization_percentage = 20
      }

      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class" = "io.confluent.connect.s3.S3SinkConnector"
    "topics"          = "change-data-capture-postgres"
    "s3.region"       = var.aws_region
    "s3.bucket.name"  = "${module.source_db.name}"
    "format.class"    = "io.confluent.connect.s3.format.json.JsonFormat"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls

      vpc {
        security_groups = [aws_security_group.example.id]
        subnets = [
          module.public_subnets.subnets[0].id,
          module.public_subnets.subnets[1].id,
          module.public_subnets.subnets[2].id
        ]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.s3_sink_plugin.arn
      revision = aws_mskconnect_custom_plugin.s3_sink_plugin.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.s3_sink_role.arn
}