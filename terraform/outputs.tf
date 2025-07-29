# RDS Outputs
output "rds_endpoint" {
  description = "The connection endpoint for the RDS instance"
  value       = module.source_db.endpoint
}

# MSK Outputs
output "msk_bootstrap_brokers_tls" {
  description = "TLS connection host:port pairs for the MSK brokers"
  value       = module.msk_cluster.bootstrap_brokers_tls
}

output "msk_bootstrap_brokers_plaintext" {
  description = "Plaintext connection host:port pairs for the MSK brokers"
  value       = module.msk_cluster.bootstrap_brokers
}

# ECS Outputs
# output "debezium_connect_service_url" {
#   description = "URL for the Debezium Connect service"
#   value       = "http://${module.debezium_connect_ecs.service_discovery_dns}:8083"
# }