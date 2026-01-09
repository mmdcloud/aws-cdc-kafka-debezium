resource "aws_mskconnect_connector" "connector" {
  name                       = var.name
  kafkaconnect_version       = var.kafkaconnect_version
  service_execution_role_arn = var.service_execution_role_arn
  dynamic "capacity" {
    for_each = var.use_autoscaling ? [1] : [0]
    content {
      autoscaling {
        mcu_count        = var.autoscaling.worker_count
        min_worker_count = var.autoscaling.min_worker_count
        max_worker_count = var.autoscaling.max_worker_count
        scale_in_policy {
          cpu_utilization_percentage = var.autoscaling.scale_in_cpu
        }
        scale_out_policy {
          cpu_utilization_percentage = var.autoscaling.scale_out_cpu
        }
      }
    }
  }
  # If not using autoscaling, render provisioned capacity instead
  dynamic "capacity" {
    for_each = var.use_autoscaling ? [] : [1]
    content {
      provisioned_capacity {
        worker_count = var.provisioned_worker_count
      }
    }
  }
  dynamic "log_delivery" {
    for_each = var.enable_log_delivery ? [1] : []
    content {
      worker_log_delivery {
        cloudwatch_logs {
          enabled         = var.log_delivery.cloudwatch_logs.enabled
          log_group       = var.log_delivery.cloudwatch_logs.log_group
        }
      }
    }
  }  
  connector_configuration = var.connector_configuration
  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.bootstrap_servers
      vpc {
        security_groups = var.security_groups
        subnets         = var.subnets
      }
    }
  }
  kafka_cluster_client_authentication {
    authentication_type = var.authentication_type
  }
  kafka_cluster_encryption_in_transit {
    encryption_type = var.encryption_type
  }
  plugin {
    custom_plugin {
      arn      = var.plugin_arn
      revision = var.plugin_revision
    }
  }
}