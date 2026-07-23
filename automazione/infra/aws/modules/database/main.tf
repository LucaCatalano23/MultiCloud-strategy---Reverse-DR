resource "aws_security_group" "database" {
  name_prefix = "${var.name_prefix}-postgres-"
  description = "PostgreSQL ingress only from EKS application workloads"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-postgres"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_eks" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from the EKS cluster security group"
  referenced_security_group_id = var.application_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-postgres"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-postgres"

  engine                   = "postgres"
  engine_version           = var.engine_version
  engine_lifecycle_support = "open-source-rds-extended-support-disabled"
  instance_class           = var.instance_class
  db_name                  = var.database_name
  username                 = var.master_username
  port                     = 5432

  manage_master_user_password = true

  allocated_storage     = var.allocated_storage_gib
  max_allocated_storage = var.max_allocated_storage_gib
  storage_type          = "gp3"
  storage_encrypted     = true

  availability_zone   = var.primary_availability_zone
  multi_az            = false
  publicly_accessible = false

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]

  iam_database_authentication_enabled = true
  auto_minor_version_upgrade           = true
  apply_immediately                     = false

  backup_retention_period = var.backup_retention_days
  backup_window           = "01:00-02:00"
  maintenance_window      = "sun:03:00-sun:04:00"
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = 0
  performance_insights_enabled    = false

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-postgres-final"

  tags = {
    Name     = "${var.name_prefix}-postgres"
    Topology = "single-az"
  }
}

# These resources reserve stable ARNs only. Secret values are populated by an
# operator/bootstrap workflow after creating a restricted PostgreSQL app user.
resource "aws_secretsmanager_secret" "application_database" {
  name                    = "${var.name_prefix}/application/database"
  description             = "Restricted application PostgreSQL credentials; never use the RDS master user at runtime"
  recovery_window_in_days = 7

  tags = {
    Name    = "${var.name_prefix}-application-database"
    Content = "operator-managed-secret-value"
  }
}

resource "aws_secretsmanager_secret" "application_config" {
  name                    = "${var.name_prefix}/application/config"
  description             = "Server-side OIDC client secret, BFF session encryption key and other runtime-only values"
  recovery_window_in_days = 7

  tags = {
    Name    = "${var.name_prefix}-application-config"
    Content = "operator-managed-secret-value"
  }
}
