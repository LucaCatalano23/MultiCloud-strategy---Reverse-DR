output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_arn" {
  value = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.main.version
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  value = aws_eks_node_group.primary.node_group_name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_subnet_ids" {
  value = var.node_subnet_ids
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_issuer_url" {
  value = local.oidc_issuer_url
}

output "load_balancer_controller_role_arn" {
  value = aws_iam_role.load_balancer_controller.arn
}
