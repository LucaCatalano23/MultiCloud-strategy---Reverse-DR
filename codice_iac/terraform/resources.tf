data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "production" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "production" {
  vpc_id = aws_vpc.production.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "database" {
  count                   = 2
  vpc_id                  = aws_vpc.production.id
  cidr_block              = cidrsubnet(aws_vpc.production.cidr_block, 8, count.index + 10)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.project_name}-db-${count.index + 1}" }
}

resource "aws_route_table" "database" {
  count  = var.db_publicly_accessible ? 1 : 0
  vpc_id = aws_vpc.production.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.production.id
  }
}

resource "aws_route_table_association" "database" {
  count          = var.db_publicly_accessible ? 2 : 0
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database[0].id
}

resource "aws_db_subnet_group" "production" {
  name       = "${var.project_name}-db"
  subnet_ids = aws_subnet.database[*].id
}

resource "aws_security_group" "database" {
  name_prefix = "${var.project_name}-db-"
  description = "Accesso PostgreSQL esplicitamente autorizzato"
  vpc_id      = aws_vpc.production.id

  dynamic "ingress" {
    for_each = toset(var.db_allowed_cidrs)
    content {
      description = "PostgreSQL da CIDR autorizzato"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_s3_bucket" "application" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "application" {
  bucket = aws_s3_bucket.application.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "application" {
  bucket = aws_s3_bucket.application.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "application" {
  bucket                  = aws_s3_bucket.application.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_db_instance" "application" {
  identifier                 = "${var.project_name}-postgres"
  engine                     = "postgres"
  engine_version             = "16"
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_storage
  max_allocated_storage      = 100
  storage_type               = "gp3"
  storage_encrypted          = true
  db_name                    = var.database_name
  username                   = var.database_username
  password                   = var.database_password
  port                       = 5432
  multi_az                   = false
  publicly_accessible        = var.db_publicly_accessible
  db_subnet_group_name       = aws_db_subnet_group.production.name
  vpc_security_group_ids     = [aws_security_group.database.id]
  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.project_name}-final"

  lifecycle { prevent_destroy = true }
}

output "s3_bucket_name" {
  description = "Bucket applicativo."
  value       = aws_s3_bucket.application.id
}

output "s3_regional_endpoint" {
  description = "Endpoint regionale S3."
  value       = aws_s3_bucket.application.bucket_regional_domain_name
}

output "database_endpoint" {
  description = "Endpoint PostgreSQL nel formato host:porta."
  value       = aws_db_instance.application.endpoint
}

output "database_address" {
  description = "Hostname PostgreSQL."
  value       = aws_db_instance.application.address
}
