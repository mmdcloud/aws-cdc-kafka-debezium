# -----------------------------------------------------------------------------------------
# Registering vault provider
# -----------------------------------------------------------------------------------------
data "vault_generic_secret" "rds" {
  path = "secret/rds"
}

# -----------------------------------------------------------------------------------------
# Random configuration
# -----------------------------------------------------------------------------------------
resource "random_id" "random" {
  byte_length = 8
}

# -----------------------------------------------------------------------------------------
# VPC Configuration
# -----------------------------------------------------------------------------------------
module "vpc" {
  source                  = "./modules/vpc"
  vpc_name                = "cdc-vpc"
  vpc_cidr                = "10.0.0.0/16"
  azs                     = var.azs
  public_subnets          = var.public_subnets
  private_subnets         = var.private_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = false
  single_nat_gateway      = false
  one_nat_gateway_per_az  = false
  tags = {
    Project = "cdc"
  }
}

# RDS Security Group    
resource "aws_security_group" "rds_sg" {
  name   = "rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "PostgreSQL traffic"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-sg"
  }
}

# MSK Security Group
resource "aws_security_group" "msk_sg" {
  name   = "msk-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "MSK traffic"
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "msk-sg"
  }
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
    module.vpc.public_subnets[0],
    module.vpc.public_subnets[1],
    module.vpc.public_subnets[2]
  ]
  vpc_security_group_ids                = [aws_security_group.rds_sg.id]
  publicly_accessible                   = true
  deletion_protection                   = false
  skip_final_snapshot                   = true
  max_allocated_storage                 = 500
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  parameter_group_name                  = "cdc-postgres17-params"
  parameter_group_family                = "postgres17"
  parameters = [
    {
      name  = "rds.logical_replication"
      value = "1"
    },
    {
      name  = "wal_sender_timeout"
      value = "0"
    },
    {
      name  = "max_replication_slots"
      value = "10"
    },
    {
      name  = "max_wal_senders"
      value = "10"
    }
  ]
}

# -----------------------------------------------------------------------------------------
# Setting up replication slots and publication
# -----------------------------------------------------------------------------------------
resource "null_resource" "setup_postgres_cdc" {
  triggers = {
    db_endpoint = module.source_db.endpoint
  }

  depends_on = [module.source_db]

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for RDS to be fully ready
      sleep 60
      
      # Set password as environment variable for security
      export PGPASSWORD='${data.vault_generic_secret.rds.data["password"]}'
      
      # Connect and create publication and slot
      psql -h ${split(":", module.source_db.endpoint)[0]} \
           -U ${data.vault_generic_secret.rds.data["username"]} \
           -d cdcsourcedb \
           -c "CREATE PUBLICATION debezium_pub FOR ALL TABLES;" \
           -c "SELECT pg_create_logical_replication_slot('debezium', 'pgoutput');"
      
      unset PGPASSWORD
    EOT
  }
}

# -----------------------------------------------------------------------------------------
# MSK Cluster
# -----------------------------------------------------------------------------------------
module "msk_cluster" {
  source                              = "./modules/msk"
  cluster_name                        = "cdc-cluster"
  kafka_version                       = "4.1.1.kraft"
  number_of_broker_nodes              = 3
  instance_type                       = "kafka.m5.large"
  client_subnets                      = module.vpc.public_subnets
  security_groups                     = [aws_security_group.msk_sg.id]
  ebs_volume_size                     = 100
  encryption_in_transit_client_broker = "TLS_PLAINTEXT"
  configuration_name                  = "cdc-demo-config"
  configuration_kafka_versions        = ["4.1.1.kraft"]
  configuration_server_properties     = <<PROPERTIES
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
  bucket_name        = "cdcdestinationbucket-${random_id.random.hex}"
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
  bucket_name = "cdcdebeziumplugins-${random_id.random.hex}"
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

# -----------------------------------------------------------------------------------------
# MSK Connector Plugins
# -----------------------------------------------------------------------------------------
resource "aws_mskconnect_custom_plugin" "debezium_postgres_plugin" {
  name         = "debezium-postgres-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = module.plugins_bucket.arn
      file_key   = "debezium-postgres-connector.zip"
    }
  }
  depends_on = [module.plugins_bucket]
}

resource "aws_mskconnect_custom_plugin" "s3_sink_plugin" {
  name         = "s3-sink-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = module.plugins_bucket.arn
      file_key   = "s3-sink.zip"
    }
  }
  depends_on = [module.plugins_bucket]
}

# -----------------------------------------------------------------------------------------
# IAM roles for MSK Connectors
# -----------------------------------------------------------------------------------------
module "debezium_connector_role" {
  source             = "./modules/iam"
  role_name          = "debezium-connector-role"
  role_description   = "IAM role for Debezium MSK Connector"
  policy_name        = "debezium-connector-policy"
  policy_description = "IAM policy for Debezium MSK Connector"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "kafkaconnect.amazonaws.com"
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
                "Resource": "${module.msk_cluster.arn}",
                "Effect": "Allow"
            },
            {
                "Action": [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents",
                  "logs:DescribeLogGroups",
                  "logs:DescribeLogStreams"
                ],
                "Resource": "*",
                "Effect": "Allow"
            },
            {
                "Action": [
                  "secretsmanager:GetSecretValue"
                ],
                "Resource": "*",
                "Effect": "Allow"
            },
            {
                "Action": [
                  "ec2:CreateNetworkInterface",
                  "ec2:DescribeNetworkInterfaces",
                  "ec2:DeleteNetworkInterface",
                  "ec2:DescribeSubnets",
                  "ec2:DescribeSecurityGroups",
                  "ec2:DescribeVpcs"
                ],
                "Resource": "*",
                "Effect": "Allow"
            }
        ]
    }
    EOF
}

module "s3_sink_role" {
  source             = "./modules/iam"
  role_name          = "s3-sink-role"
  role_description   = "IAM role for S3 Sink Connector"
  policy_name        = "s3-sink-policy"
  policy_description = "IAM policy for S3 Sink Connector"
  assume_role_policy = <<EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "s3.amazonaws.com"
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
                "Resource": "${module.msk_cluster.arn}",
                "Effect": "Allow"
            },
            {
                "Action": [
                  "s3:PutObject",
                  "s3:GetObject",
                  "s3:ListBucket",
                  "s3:AbortMultipartUpload",
                  "s3:GetBucketLocation"
                ],
                "Resource": [
                  "${module.destination_bucket.arn}",
                  "${module.destination_bucket.arn}/*"
                ],
                "Effect": "Allow"
            },
            {
                "Action": [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents",
                  "logs:DescribeLogGroups",
                  "logs:DescribeLogStreams"
                ],
                "Resource": "*",
                "Effect": "Allow"
            },
            {
                "Action": [
                  "ec2:CreateNetworkInterface",
                  "ec2:DescribeNetworkInterfaces",
                  "ec2:DeleteNetworkInterface",
                  "ec2:DescribeSubnets",
                  "ec2:DescribeSecurityGroups",
                  "ec2:DescribeVpcs"
                ],
                "Resource": "*",
                "Effect": "Allow"
            }
        ]
    }
    EOF
}

# -----------------------------------------------------------------------------------------
# MSK Connectors
# -----------------------------------------------------------------------------------------
module "debezium_postgres_connector" {
  source = "./modules/msk_connector"
  name                 = "debezium-postgres-connector"
  kafkaconnect_version = "2.7.1"
  connector_configuration = {
    "connector.class"      = "io.debezium.connector.postgresql.PostgresConnector"
    "database.hostname"    = split(":", module.source_db.endpoint)[0]
    "database.port"        = "5432"
    "database.dbname"      = "cdcsourcedb"
    "database.server.name" = "postgres-cdc"
    "plugin.name"          = "pgoutput"
    "slot.name"            = "debezium"
    "publication.name"     = "debezium_pub"
    "database.user"        = tostring(data.vault_generic_secret.rds.data["username"])
    "database.password"    = tostring(data.vault_generic_secret.rds.data["password"])
    "tasks.max"            = "1"
  }
  bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls
  security_groups = [
    aws_security_group.msk_sg.id
  ]
  subnets = [
    module.vpc.public_subnets[0],
    module.vpc.public_subnets[1],
    module.vpc.public_subnets[2]
  ]
  authentication_type = "NONE"
  encryption_type     = "TLS"
  plugin_arn      = aws_mskconnect_custom_plugin.debezium_postgres_plugin.arn
  plugin_revision = aws_mskconnect_custom_plugin.debezium_postgres_plugin.latest_revision
  service_execution_role_arn = module.debezium_connector_role.arn
  use_autoscaling = true
  autoscaling = {
    worker_count     = 1
    min_worker_count = 1
    max_worker_count = 2
    scale_in_cpu     = 20
    scale_out_cpu    = 80
  }
  depends_on = [module.msk_cluster]
}

# resource "aws_mskconnect_connector" "debezium_postgres_connector" {
#   name = "debezium-postgres-connector"

#   kafkaconnect_version = "2.7.1"

#   capacity {
#     autoscaling {
#       mcu_count        = 1
#       min_worker_count = 1
#       max_worker_count = 2

#       scale_in_policy {
#         cpu_utilization_percentage = 20
#       }

#       scale_out_policy {
#         cpu_utilization_percentage = 80
#       }
#     }
#   }

#   connector_configuration = {
#     "connector.class"      = "io.debezium.connector.postgresql.PostgresConnector"
#     "database.hostname"    = "${split(":", module.source_db.endpoint)[0]}"
#     "database.port"        = 5432
#     "database.dbname"      = "cdcsourcedb"
#     "database.server.name" = "postgres-cdc"
#     "plugin.name"          = "pgoutput"
#     "slot.name"            = "debezium"
#     "publication.name"     = "debezium_pub"
#     "database.user"        = tostring(data.vault_generic_secret.rds.data["username"])
#     "database.password"    = tostring(data.vault_generic_secret.rds.data["password"])
#     "tasks.max"            = "1"
#   }

#   kafka_cluster {
#     apache_kafka_cluster {
#       bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls

#       vpc {
#         security_groups = [aws_security_group.msk_sg.id]
#         subnets = [
#           module.vpc.public_subnets[0],
#           module.vpc.public_subnets[1],
#           module.vpc.public_subnets[2]
#         ]
#       }
#     }
#   }

#   kafka_cluster_client_authentication {
#     authentication_type = "NONE"
#   }

#   kafka_cluster_encryption_in_transit {
#     encryption_type = "TLS"
#   }

#   plugin {
#     custom_plugin {
#       arn      = aws_mskconnect_custom_plugin.debezium_postgres_plugin.arn
#       revision = aws_mskconnect_custom_plugin.debezium_postgres_plugin.latest_revision
#     }
#   }

#   service_execution_role_arn = module.debezium_connector_role.arn

#   depends_on = [module.msk_cluster]
# }

module "s3_sink_connector" {
  source               = "./modules/msk_connector"
  name                 = "s3-sink-connector"
  kafkaconnect_version = "2.7.1"
  connector_configuration = {
    "connector.class"    = "io.confluent.connect.s3.S3SinkConnector"
    "topics.regex"       = "postgres-cdc.*"
    "s3.region"          = var.aws_region
    "s3.bucket.name"     = module.destination_bucket.bucket
    "format.class"       = "io.confluent.connect.s3.format.json.JsonFormat"
    "tasks.max"          = "1"
    "flush.size"         = "1000"
    "rotate.interval.ms" = "60000"
    "storage.class"      = "io.confluent.connect.s3.storage.S3Storage"
  }
  bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls
  security_groups   = [aws_security_group.msk_sg.id]
  subnets           = module.vpc.public_subnets
  authentication_type = "NONE"
  encryption_type     = "TLS"
  plugin_arn      = aws_mskconnect_custom_plugin.s3_sink_plugin.arn
  plugin_revision = aws_mskconnect_custom_plugin.s3_sink_plugin.latest_revision
  service_execution_role_arn = module.s3_sink_role.arn
  use_autoscaling = true
  autoscaling = {
    worker_count     = 1
    min_worker_count = 1
    max_worker_count = 2
    scale_in_cpu     = 20
    scale_out_cpu    = 80
  }
  depends_on = [module.msk_cluster]
}

# resource "aws_mskconnect_connector" "s3_sink_connector" {
#   name = "s3-sink-connector"

#   kafkaconnect_version = "2.7.1"

#   capacity {
#     autoscaling {
#       mcu_count        = 1
#       min_worker_count = 1
#       max_worker_count = 2
#       scale_in_policy {
#         cpu_utilization_percentage = 20
#       }
#       scale_out_policy {
#         cpu_utilization_percentage = 80
#       }
#     }
#   }
#   connector_configuration = {
#     "connector.class"    = "io.confluent.connect.s3.S3SinkConnector"
#     "topics.regex"       = "postgres-cdc.*"
#     "s3.region"          = var.aws_region
#     "s3.bucket.name"     = "${module.destination_bucket.bucket}"
#     "format.class"       = "io.confluent.connect.s3.format.json.JsonFormat"
#     "tasks.max"          = "1"
#     "flush.size"         = "1000"
#     "rotate.interval.ms" = "60000"
#     "storage.class"      = "io.confluent.connect.s3.storage.S3Storage"
#   }
#   kafka_cluster {
#     apache_kafka_cluster {
#       bootstrap_servers = module.msk_cluster.bootstrap_brokers_tls
#       vpc {
#         security_groups = [aws_security_group.msk_sg.id]
#         subnets = [
#           module.vpc.public_subnets[0],
#           module.vpc.public_subnets[1],
#           module.vpc.public_subnets[2]
#         ]
#       }
#     }
#   }
#   kafka_cluster_client_authentication {
#     authentication_type = "NONE"
#   }
#   kafka_cluster_encryption_in_transit {
#     encryption_type = "TLS"
#   }
#   plugin {
#     custom_plugin {
#       arn      = aws_mskconnect_custom_plugin.s3_sink_plugin.arn
#       revision = aws_mskconnect_custom_plugin.s3_sink_plugin.latest_revision
#     }
#   }
#   service_execution_role_arn = module.s3_sink_role.arn
#   depends_on                 = [module.msk_cluster]
# }