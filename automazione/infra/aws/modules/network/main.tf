data "aws_ami" "amazon_linux_2023_arm64" {
  count = var.nat_ami_id == null ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  nat_ami_id = coalesce(var.nat_ami_id, try(data.aws_ami.amazon_linux_2023_arm64[0].id, null))
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "primary_public" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.primary_availability_zone
  cidr_block              = var.primary_public_subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name_prefix}-public-primary"
    Tier                     = "public"
    Purpose                  = "nat-and-alb"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "witness_public" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.witness_availability_zone
  cidr_block              = var.witness_public_subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name_prefix}-public-witness"
    Tier                     = "public"
    Purpose                  = "alb-minimum-second-az"
    Workloads                = "prohibited"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "primary_private" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.primary_availability_zone
  cidr_block              = var.primary_private_subnet_cidr
  map_public_ip_on_launch = false

  tags = {
    Name      = "${var.name_prefix}-private-primary"
    Tier      = "private"
    Purpose   = "eks-nodes-pods-and-rds"
    Workloads = "allowed"
  }
}

resource "aws_subnet" "witness_private" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.witness_availability_zone
  cidr_block              = var.witness_private_subnet_cidr
  map_public_ip_on_launch = false

  tags = {
    Name      = "${var.name_prefix}-private-witness"
    Tier      = "private"
    Purpose   = "eks-control-plane-and-rds-subnet-group"
    Workloads = "prohibited"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "primary_public" {
  subnet_id      = aws_subnet.primary_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "witness_public" {
  subnet_id      = aws_subnet.witness_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "nat" {
  name_prefix = "${var.name_prefix}-nat-"
  description = "Forward egress only from the primary private subnet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_primary_private" {
  security_group_id = aws_security_group.nat.id
  description       = "Forward traffic from the primary private subnet"
  cidr_ipv4         = var.primary_private_subnet_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_to_internet" {
  security_group_id = aws_security_group.nat.id
  description       = "Outbound internet egress for private workloads"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "nat" {
  ami                         = local.nat_ami_id
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.primary_public.id
  vpc_security_group_ids      = [aws_security_group.nat.id]
  associate_public_ip_address = true
  source_dest_check           = false

  user_data_replace_on_change = true
  user_data                   = <<-USER_DATA
    #!/bin/bash
    set -euxo pipefail

    dnf install -y iptables-services
    cat >/etc/sysctl.d/90-nat.conf <<'SYSCTL'
    net.ipv4.ip_forward = 1
    SYSCTL
    sysctl --system

    default_interface="$(ip route show default | awk '{print $5; exit}')"
    iptables -t nat -C POSTROUTING -o "$default_interface" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -o "$default_interface" -j MASQUERADE
    iptables-save >/etc/sysconfig/iptables
    systemctl enable --now iptables
  USER_DATA

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    encrypted             = true
    delete_on_termination = true
    volume_type           = "gp3"
    volume_size           = 8
  }

  tags = {
    Name    = "${var.name_prefix}-nat"
    Purpose = "cost-conscious-nat-instance"
  }

  volume_tags = {
    Name = "${var.name_prefix}-nat-root"
  }

  lifecycle {
    precondition {
      condition     = local.nat_ami_id != null
      error_message = "A NAT AMI must be supplied or discoverable from Amazon Linux 2023 ARM64 images."
    }
  }
}

resource "aws_eip" "nat" {
  domain   = "vpc"
  instance = aws_instance.nat.id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "primary_private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-primary"
  }
}

resource "aws_route" "primary_private_egress" {
  route_table_id         = aws_route_table.primary_private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

resource "aws_route_table_association" "primary_private" {
  subnet_id      = aws_subnet.primary_private.id
  route_table_id = aws_route_table.primary_private.id
}

resource "aws_route_table" "witness_private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-witness-isolated"
  }
}

resource "aws_route_table_association" "witness_private" {
  subnet_id      = aws_subnet.witness_private.id
  route_table_id = aws_route_table.witness_private.id
}

resource "aws_cloudwatch_log_group" "vpc_flow" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name_prefix}/flow"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "vpc_flow" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = "write-cloudwatch-logs"
  role = aws_iam_role.vpc_flow[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  iam_role_arn             = aws_iam_role.vpc_flow[0].arn
  log_destination          = aws_cloudwatch_log_group.vpc_flow[0].arn
  log_destination_type     = "cloud-watch-logs"
  traffic_type             = "ALL"
  vpc_id                   = aws_vpc.main.id
  max_aggregation_interval = 600

  depends_on = [aws_iam_role_policy.vpc_flow]
}
