resource "aws_msk_cluster" "cluster" {
  cluster_name           = var.cluster_name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.number_of_broker_nodes

  broker_node_group_info {
    instance_type   = var.instance_type
    client_subnets  = var.client_subnets
    security_groups = var.security_groups
    storage_info {
      ebs_storage_info {
        volume_size = var.ebs_volume_size
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.cdc_config.arn
    revision = aws_msk_configuration.cdc_config.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = var.encryption_in_transit_client_broker
    }
  }

#   open_monitoring {
#     prometheus {
#       jmx_exporter {
#         enabled_in_broker = true
#       }
#       node_exporter {
#         enabled_in_broker = true
#       }
#     }
#   }
}

resource "aws_msk_configuration" "cdc_config" {
  kafka_versions = var.configuration_kafka_versions
  name           = var.configuration_name
  server_properties = var.configuration_server_properties
}