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
  database_subnets        = var.database_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = true
  single_nat_gateway      = true
  one_nat_gateway_per_az  = false
  tags = {
    Project = "cdc"
  }
}

# RDS Security Group
module "rds_sg" {
  source = "./modules/security-groups"
  name   = "rds-sg"
  vpc_id = module.vpc.vpc_id
  ingress_rules = [
    {
      description     = "PostgreSQL Traffic from Private Subnets"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      cidr_blocks     = concat(var.database_subnets, var.private_subnets)
      security_groups = []
    }
  ]
  egress_rules = [
    {
      description = "Allow all outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  tags = {
    Name = "rds-sg"
  }
}

# MSK Security Group
module "msk_sg" {
  source = "./modules/security-groups"
  name   = "msk-sg"
  vpc_id = module.vpc.vpc_id
  ingress_rules = [
    {
      description     = "MSK Traffic"
      from_port       = 9092
      to_port         = 9098
      protocol        = "tcp"
      security_groups = []
      self            = true
      cidr_blocks     = ["0.0.0.0/0"]
    }
  ]
  egress_rules = [
    {
      description = "Allow all outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  tags = {
    Name = "msk-sg"
  }
}

resource "aws_security_group_rule" "rds_from_msk_connectors" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.msk_sg.id
  security_group_id        = module.rds_sg.id
  description              = "Allow MSK Connectors to access RDS"
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
    module.vpc.database_subnets[0],
    module.vpc.database_subnets[1],
    module.vpc.database_subnets[2]
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
    {
      name         = "rds.logical_replication"
      value        = "1"
      apply_method = "pending-reboot"
    },
    {
      name         = "max_replication_slots"
      value        = "10"
      apply_method = "pending-reboot"
    },
    {
      name         = "max_wal_senders"
      value        = "10"
      apply_method = "pending-reboot"
    },
    {
      name         = "max_worker_processes"
      value        = "8"
      apply_method = "pending-reboot"
    },
    {
      name         = "max_logical_replication_workers"
      value        = "4"
      apply_method = "pending-reboot"
    }

    # # DYNAMIC PARAMETERS - No reboot required
    # {
    #   name         = "wal_sender_timeout"
    #   value        = "0"
    #   apply_method = "immediate"
    # },
    # {
    #   name         = "log_min_duration_statement"
    #   value        = "1000"
    #   apply_method = "immediate"
    # }
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
      cat > ~/.pgpass << EOF
${split(":", module.source_db.endpoint)[0]}:5432:cdcsourcedb:${data.vault_generic_secret.rds.data["username"]}:${data.vault_generic_secret.rds.data["password"]}
EOF
      chmod 600 ~/.pgpass
      
      # Create publication
      psql -h ${split(":", module.source_db.endpoint)[0]} \
           -U ${data.vault_generic_secret.rds.data["username"]} \
           -d cdcsourcedb \
           -c "CREATE PUBLICATION IF NOT EXISTS debezium_pub FOR ALL TABLES;"

      psql -h ${split(":", module.source_db.endpoint)[0]} \
     -U ${data.vault_generic_secret.rds.data["username"]} \
     -d cdcsourcedb \
     -c "CREATE TABLE IF NOT EXISTS heartbeat (status INT PRIMARY KEY);"
      
      # Create replication slot only if it doesn't exist
      psql -h ${split(":", module.source_db.endpoint)[0]} \
           -U ${data.vault_generic_secret.rds.data["username"]} \
           -d cdcsourcedb \
           -c "SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'debezium') THEN pg_create_logical_replication_slot('debezium', 'pgoutput') END;" \
           2>&1 || true
      
      rm ~/.pgpass
    EOT
  }
}

# -----------------------------------------------------------------------------------------
# MSK Cluster
# -----------------------------------------------------------------------------------------
module "msk_cluster" {
  source                              = "./modules/msk"
  cluster_name                        = "cdc-cluster"
  kafka_version                       = "4.1.x.kraft"
  number_of_broker_nodes              = 3
  instance_type                       = "kafka.m5.large"
  client_subnets                      = module.vpc.private_subnets
  security_groups                     = [module.msk_sg.id]
  ebs_volume_size                     = 100
  encryption_in_transit_client_broker = "TLS_PLAINTEXT"
  configuration_name                  = "cdc-demo-config"
  configuration_kafka_versions        = ["4.1.x.kraft"]
  configuration_server_properties     = <<PROPERTIES
# Enable dynamic topic creation for Debezium
auto.create.topics.enable=true
delete.topic.enable=true

# Partition settings
num.partitions=3
default.replication.factor=3

# Data retention (7 days)
log.retention.hours=168
log.segment.bytes=1073741824

# Replication settings for durability
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2

# Performance tuning
num.io.threads=8
num.network.threads=5
num.replica.fetchers=2
replica.lag.time.max.ms=30000

# Message size limits (important for CDC payloads)
message.max.bytes=1048588
replica.fetch.max.bytes=1048576
socket.request.max.bytes=104857600

# Compression for storage efficiency
compression.type=snappy

# Reliability settings
unclean.leader.election.enable=false

# Consumer group settings
group.min.session.timeout.ms=6000
group.max.session.timeout.ms=1800000
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
      source = "../connectors/debezium-connector-postgres.zip"
    },
    {
      key    = "s3-sink.zip"
      source = "../connectors/s3-sink-connector.zip"
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
module "debezium_connector_log_group" {
  source            = "./modules/cloudwatch/cloudwatch-log-group"
  log_group_name    = "/aws/mskconnect/debezium-postgres-connector"
  retention_in_days = 90
}

module "s3_sink_connector_log_group" {
  source            = "./modules/cloudwatch/cloudwatch-log-group"
  log_group_name    = "/aws/mskconnect/s3-sink-connector"
  retention_in_days = 90
}

module "debezium_postgres_connector" {
  source               = "./modules/msk_connector"
  name                 = "debezium-postgres-connector"
  kafkaconnect_version = "2.7.1"
  connector_configuration = {
    # Core connector settings
    "connector.class"      = "io.debezium.connector.postgresql.PostgresConnector"
    "database.hostname"    = split(":", module.source_db.endpoint)[0]
    "database.port"        = "5432"
    "database.dbname"      = "cdcsourcedb"
    "database.server.name" = "postgres-cdc"

    # Postgres-specific settings
    "plugin.name"                 = "pgoutput"
    "slot.name"                   = "debezium"
    "publication.name"            = "debezium_pub"
    "publication.autocreate.mode" = "filtered"
    "slot.drop.on.stop"           = "false"

    # Authentication
    "database.user"     = tostring(data.vault_generic_secret.rds.data["username"])
    "database.password" = tostring(data.vault_generic_secret.rds.data["password"])

    # Task configuration
    "tasks.max" = "1"

    # Topic configuration
    "topic.prefix"       = "postgres-cdc"
    "table.include.list" = "public.*"

    # Schema history (required for Debezium)
    "schema.history.internal.kafka.bootstrap.servers"         = module.msk_cluster.bootstrap_brokers
    "schema.history.internal.kafka.topic"                     = "schema-changes.postgres"
    "schema.history.internal.kafka.recovery.poll.interval.ms" = "1000"
    "schema.history.internal.kafka.recovery.attempts"         = "100"
    "schema.history.internal.consumer.security.protocol"      = "PLAINTEXT"
    "schema.history.internal.producer.security.protocol"      = "PLAINTEXT"

    # Heartbeat to prevent slot timeout
    "heartbeat.interval.ms"  = "10000"
    "heartbeat.action.query" = "INSERT INTO heartbeat (status) VALUES (1) ON CONFLICT DO NOTHING"

    # Snapshot configuration
    "snapshot.mode"         = "initial"
    "snapshot.locking.mode" = "none"

    # Error handling
    "errors.tolerance"            = "all"
    "errors.log.enable"           = "true"
    "errors.log.include.messages" = "true"

    # Converters
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"

    # Performance tuning
    "max.batch.size"   = "2048"
    "max.queue.size"   = "8192"
    "poll.interval.ms" = "1000"
  }

  enable_log_delivery = true
  log_delivery = {
    cloudwatch_logs = {
      enabled   = true
      log_group = module.debezium_connector_log_group.name
    }
  }

  bootstrap_servers = module.msk_cluster.bootstrap_brokers
  security_groups   = [module.msk_sg.id]
  subnets = [
    module.vpc.private_subnets[0],
    module.vpc.private_subnets[1],
    module.vpc.private_subnets[2]
  ]

  authentication_type        = "NONE"
  encryption_type            = "PLAINTEXT"
  plugin_arn                 = aws_mskconnect_custom_plugin.debezium_postgres_plugin.arn
  plugin_revision            = aws_mskconnect_custom_plugin.debezium_postgres_plugin.latest_revision
  service_execution_role_arn = module.debezium_connector_role.arn

  use_autoscaling = true
  autoscaling = {
    worker_count     = 1
    min_worker_count = 1
    max_worker_count = 2
    scale_in_cpu     = 20
    scale_out_cpu    = 80
  }

  depends_on = [
    module.msk_cluster,
    null_resource.setup_postgres_cdc
  ]
}

module "s3_sink_connector" {
  source               = "./modules/msk_connector"
  name                 = "s3-sink-connector"
  kafkaconnect_version = "2.7.1"
  connector_configuration = {
    # Core connector settings
    "connector.class" = "io.confluent.connect.s3.S3SinkConnector"
    "topics.regex"    = "postgres-cdc\\..*" # Escaped dot for proper regex
    "tasks.max"       = "2"

    # S3 configuration
    "s3.region"      = var.aws_region
    "s3.bucket.name" = module.destination_bucket.bucket
    "s3.part.size"   = "5242880"

    # Format settings
    "format.class"  = "io.confluent.connect.s3.format.json.JsonFormat"
    "storage.class" = "io.confluent.connect.s3.storage.S3Storage"

    # Partitioning
    "partitioner.class"     = "io.confluent.connect.storage.partitioner.TimeBasedPartitioner"
    "path.format"           = "'year'=YYYY/'month'=MM/'day'=dd/'hour'=HH"
    "partition.duration.ms" = "3600000"
    "timezone"              = "UTC"
    "timestamp.extractor"   = "Record"
    "locale"                = "en-US"

    # Flush settings
    "flush.size"         = "1000"
    "rotate.interval.ms" = "60000"

    # Schema settings
    "schema.compatibility" = "NONE"

    # Error handling
    "errors.tolerance"                  = "all"
    "errors.log.enable"                 = "true"
    "errors.log.include.messages"       = "true"
    "errors.deadletterqueue.topic.name" = "dlq-s3-sink"

    # Converters (must match Debezium output)
    "key.converter"                  = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"   = "false"
    "value.converter"                = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter.schemas.enable" = "false"

    # Behavior settings
    "behavior.on.null.values" = "ignore"
  }

  enable_log_delivery = true
  log_delivery = {
    cloudwatch_logs = {
      enabled   = true
      log_group = module.s3_sink_connector_log_group.name
    }
  }

  bootstrap_servers          = module.msk_cluster.bootstrap_brokers
  security_groups            = [module.msk_sg.id]
  subnets                    = module.vpc.private_subnets
  authentication_type        = "NONE"
  encryption_type            = "PLAINTEXT"
  plugin_arn                 = aws_mskconnect_custom_plugin.s3_sink_plugin.arn
  plugin_revision            = aws_mskconnect_custom_plugin.s3_sink_plugin.latest_revision
  service_execution_role_arn = module.s3_sink_role.arn

  use_autoscaling = true
  autoscaling = {
    worker_count     = 1
    min_worker_count = 1
    max_worker_count = 2
    scale_in_cpu     = 20
    scale_out_cpu    = 80
  }

  depends_on = [
    module.msk_cluster,
    module.debezium_postgres_connector
  ]
}

# -----------------------------------------------------------------------------------------
# SNS Topic for Alarm Notifications
# -----------------------------------------------------------------------------------------
module "cdc_alarm_notifications" {
  source     = "./modules/sns"
  topic_name = "cdc-alarm-notifications"
  subscriptions = [
    {
      protocol = "email"
      endpoint = var.notification_email
    }
  ]
}

# -----------------------------------------------------------------------------------------
# RDS CloudWatch Alarms
# -----------------------------------------------------------------------------------------

# RDS CPU Utilization
module "rds_cpu_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "rds-high-cpu-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "RDS CPU utilization is above 80%"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    DBInstanceIdentifier = module.source_db.db_instance_id
  }
}

# RDS Freeable Memory
module "rds_memory_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "rds-low-freeable-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "1073741824" # 1 GB in bytes
  alarm_description   = "RDS freeable memory is below 1 GB"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    DBInstanceIdentifier = module.source_db.db_instance_id
  }
}

# RDS Database Connections
module "rds_connections_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "rds-high-database-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "RDS database connections are high"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    DBInstanceIdentifier = module.source_db.db_instance_id
  }
}

# RDS Replication Slot Lag (Critical for CDC)
module "rds_replication_lag_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "rds-replication-slot-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "OldestReplicationSlotLag"
  namespace           = "AWS/RDS"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "1000" # 1000 MB
  alarm_description   = "RDS replication slot lag is high - CDC may be falling behind"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    DBInstanceIdentifier = module.source_db.db_instance_id
  }
}

# RDS Disk Queue Depth
module "rds_disk_queue_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "rds-high-disk-queue-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "DiskQueueDepth"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "10"
  alarm_description   = "RDS disk queue depth is high"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    DBInstanceIdentifier = module.source_db.db_instance_id
  }
}

# RDS Free Storage Space
module "rds_storage_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "rds-low-storage-space"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "10737418240" # 10 GB in bytes
  alarm_description   = "RDS free storage space is below 10 GB"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    DBInstanceIdentifier = module.source_db.db_instance_id
  }
}

# MSK CPU Utilization
module "msk_cpu_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-high-cpu-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CpuUser"
  namespace           = "AWS/Kafka"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "MSK CPU utilization is above 80%"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name" = module.msk_cluster.cluster_name
  }
}

# MSK Disk Space Usage
module "msk_disk_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-high-disk-usage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "KafkaDataLogsDiskUsed"
  namespace           = "AWS/Kafka"
  period              = "300"
  statistic           = "Average"
  threshold           = "80" # 80% disk usage
  alarm_description   = "MSK disk usage is above 80%"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name" = module.msk_cluster.cluster_name
  }
}

# MSK Under Replicated Partitions
module "msk_under_replicated_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-under-replicated-partitions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "UnderReplicatedPartitions"
  namespace           = "AWS/Kafka"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "0"
  alarm_description   = "MSK has under-replicated partitions - data durability at risk"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name" = module.msk_cluster.cluster_name
  }
}

# MSK Offline Partitions
module "msk_offline_partitions_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-offline-partitions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "OfflinePartitionsCount"
  namespace           = "AWS/Kafka"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "0"
  alarm_description   = "MSK has offline partitions - CRITICAL"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name" = module.msk_cluster.cluster_name
  }
}

# MSK Active Controller Count
module "msk_active_controller_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-no-active-controller"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ActiveControllerCount"
  namespace           = "AWS/Kafka"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "1"
  alarm_description   = "MSK has no active controller - cluster issues"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name" = module.msk_cluster.cluster_name
  }
}

# MSK Network Throughput (Incoming)
module "msk_network_in_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-high-network-incoming"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "BytesInPerSec"
  namespace           = "AWS/Kafka"
  period              = "300"
  statistic           = "Average"
  threshold           = "100000000" # 100 MB/s
  alarm_description   = "MSK incoming network throughput is high"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name" = module.msk_cluster.cluster_name
  }
}

# MSK Consumer Lag (Critical for CDC pipeline)
module "msk_consumer_lag_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "msk-high-consumer-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "EstimatedMaxTimeLag"
  namespace           = "AWS/Kafka"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "300000" # 5 minutes in milliseconds
  alarm_description   = "MSK consumer lag is above 5 minutes"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "Cluster Name"   = module.msk_cluster.cluster_name
    "Consumer Group" = "connect-s3-sink-connector" # Adjust based on your consumer group
  }
}

# Debezium Connector Failed Tasks
module "debezium_failed_tasks_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "debezium-connector-failed-tasks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "task-count"
  namespace           = "AWS/KafkaConnect"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "0"
  alarm_description   = "Debezium connector has failed tasks - CDC may be stopped"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "connector-name" = module.debezium_postgres_connector.connector_name
    "task-state"     = "failed"
  }
}

# Debezium Connector Running Tasks
module "debezium_running_tasks_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "debezium-connector-no-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "task-count"
  namespace           = "AWS/KafkaConnect"
  period              = "300"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "Debezium connector has no running tasks"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "connector-name" = module.debezium_postgres_connector.connector_name
    "task-state"     = "running"
  }
}

# -----------------------------------------------------------------------------------------
# MSK Connect (S3 Sink Connector) CloudWatch Alarms
# -----------------------------------------------------------------------------------------

# S3 Sink Connector Failed Tasks
module "s3_sink_failed_tasks_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "s3-sink-connector-failed-tasks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "task-count"
  namespace           = "AWS/KafkaConnect"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "0"
  alarm_description   = "S3 Sink connector has failed tasks - data may not be written to S3"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "connector-name" = module.s3_sink_connector.connector_name
    "task-state"     = "failed"
  }
}

# S3 Sink Connector Running Tasks
module "s3_sink_running_tasks_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "s3-sink-connector-no-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "task-count"
  namespace           = "AWS/KafkaConnect"
  period              = "300"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "S3 Sink connector has no running tasks"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]

  dimensions = {
    "connector-name" = module.s3_sink_connector.connector_name
    "task-state"     = "running"
  }
}

module "debezium_error_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "debezium-connector-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "DebeziumErrorCount"
  namespace           = "CDC/Connectors"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "Debezium connector has errors in logs"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {}
}

module "s3_sink_error_alarm" {
  source              = "./modules/cloudwatch/cloudwatch-alarm"
  alarm_name          = "s3-sink-connector-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "S3SinkErrorCount"
  namespace           = "CDC/Connectors"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "S3 Sink connector has errors in logs"
  alarm_actions       = [module.cdc_alarm_notifications.topic_arn]
  ok_actions          = [module.cdc_alarm_notifications.topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {}
}
