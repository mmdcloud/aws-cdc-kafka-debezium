# Outputs
output "rds_endpoint" {
  value = module.source_db.endpoint
}

output "kafka_bootstrap_brokers" {
  value = module.msk_cluster.bootstrap_brokers_tls
}

# output "debezium_connect_endpoint" {
#   value = "${aws_ecs_service.debezium_connect.name}.${aws_ecs_cluster.debezium.name}"
# }