output "bootstrap_brokers_tls" {
  value = aws_msk_cluster.cluster.bootstrap_brokers_tls
}

output "bootstrap_brokers" {
  value = aws_msk_cluster.cluster.bootstrap_brokers
}

output "arn" {
  value = aws_msk_cluster.cluster.arn
}