data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  oidc_issuer_url      = aws_eks_cluster.main.identity[0].oidc[0].issuer
  oidc_issuer_hostpath = replace(local.oidc_issuer_url, "https://", "")
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url = local.oidc_issuer_url

  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    data.tls_certificate.cluster.certificates[length(data.tls_certificate.cluster.certificates) - 1].sha1_fingerprint,
  ]

  tags = {
    Name = "${var.name_prefix}-eks-irsa"
  }
}

data "aws_iam_policy_document" "vpc_cni_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.name_prefix}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_trust.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${var.aws_partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${var.aws_partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  service_account_role_arn    = aws_iam_role.vpc_cni.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_iam_role_policy_attachment.vpc_cni]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.primary]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [
    aws_eks_node_group.primary,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}
