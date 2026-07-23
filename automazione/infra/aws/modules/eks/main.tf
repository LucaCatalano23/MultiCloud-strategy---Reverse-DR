resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name_prefix}/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "main" {
  name     = var.name_prefix
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = var.control_plane_log_types

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.cluster_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  tags = {
    Name     = var.name_prefix
    Topology = "single-az-workers-with-witness-control-plane-subnet"
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
  ]
}

resource "aws_eks_access_entry" "administrator" {
  for_each = var.admin_principal_arns

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "administrator" {
  for_each = var.admin_principal_arns

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:${var.aws_partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.administrator]
}

resource "aws_launch_template" "node" {
  name_prefix            = "${var.name_prefix}-primary-"
  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted             = true
      delete_on_termination = true
      volume_type           = "gp3"
      volume_size           = var.node_disk_size_gib
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-eks-primary"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name = "${var.name_prefix}-eks-primary"
    }
  }
}

resource "aws_eks_node_group" "primary" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name_prefix}-primary"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.node_subnet_ids
  capacity_type   = var.node_capacity_type
  instance_types  = var.node_instance_types
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "reverse-dr.io/failure-domain" = "primary-az"
    "reverse-dr.io/workload-tier"  = "application"
  }

  tags = {
    Name     = "${var.name_prefix}-primary"
    Topology = "single-az"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
