# Outputs
output "rds_endpoint" {
  value = aws_db_instance.source_db.endpoint
}

output "kafka_bootstrap_brokers" {
  value = aws_msk_cluster.cdc_kafka.bootstrap_brokers_tls
}

output "debezium_connect_endpoint" {
  value = "${aws_ecs_service.debezium_connect.name}.${aws_ecs_cluster.debezium.name}"
}