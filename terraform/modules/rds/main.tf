# MunchGo Microservices - Amazon RDS PostgreSQL
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 1: Cloud Foundations
# Single RDS PostgreSQL 16 instance with 6 databases (one per microservice).
# Each service uses Flyway for schema migrations on startup.
#
# Database mapping:
#   auth       → munchgo-auth-service        (users, roles, refresh_tokens)
#   consumers  → munchgo-consumer-service     (consumers, addresses)
#   restaurants→ munchgo-restaurant-service    (restaurants, menu_items)
#   couriers   → munchgo-courier-service      (couriers, availability)
#   orders     → munchgo-order-service        (event_store, order_views)
#   sagas      → munchgo-order-saga-orchestrator (sagas, saga_steps)
#
# All services include an outbox_events table for Transactional Outbox pattern.

# ==============================================================================
# SECRETS MANAGER - Master Credentials
# ==============================================================================

resource "random_password" "rds_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "rds_master" {
  name_prefix = "${var.name_prefix}-munchgo-rds-"
  description = "MunchGo RDS PostgreSQL master credentials"

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-rds-secret"
    Layer  = "Layer1-CloudFoundations"
    Module = "rds"
  })
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.rds_master.result
    engine   = "postgres"
    host     = aws_db_instance.munchgo.address
    port     = aws_db_instance.munchgo.port
    dbname   = var.master_db_name
  })
}

# Store individual database credentials for each service
resource "aws_secretsmanager_secret" "munchgo_db" {
  for_each = toset(var.service_databases)

  name_prefix = "${var.name_prefix}-munchgo-${each.value}-db-"
  description = "MunchGo ${each.value} database credentials"

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-munchgo-${each.value}-db-secret"
    Layer   = "Layer1-CloudFoundations"
    Module  = "rds"
    Service = each.value
  })
}

resource "aws_secretsmanager_secret_version" "munchgo_db" {
  for_each = toset(var.service_databases)

  secret_id = aws_secretsmanager_secret.munchgo_db[each.value].id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.rds_master.result
    host     = aws_db_instance.munchgo.address
    port     = tostring(aws_db_instance.munchgo.port)
    dbname   = each.value
    url      = "jdbc:postgresql://${aws_db_instance.munchgo.address}:${aws_db_instance.munchgo.port}/${each.value}"
  })
}

# ==============================================================================
# DB SUBNET GROUP
# ==============================================================================

resource "aws_db_subnet_group" "munchgo" {
  name_prefix = "${var.name_prefix}-munchgo-"
  subnet_ids  = var.private_subnet_ids
  description = "Subnet group for MunchGo RDS PostgreSQL"

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-db-subnet-group"
    Layer  = "Layer1-CloudFoundations"
    Module = "rds"
  })
}

# ==============================================================================
# SECURITY GROUP
# ==============================================================================

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-munchgo-rds-"
  vpc_id      = var.vpc_id
  description = "Security group for MunchGo RDS PostgreSQL"

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-rds-sg"
    Layer  = "Layer1-CloudFoundations"
    Module = "rds"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================================================
# RDS INSTANCE
# ==============================================================================

resource "aws_db_instance" "munchgo" {
  identifier_prefix = "${var.name_prefix}-munchgo-"

  engine               = "postgres"
  engine_version       = var.engine_version
  instance_class       = var.instance_class
  allocated_storage    = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type         = "gp3"
  storage_encrypted    = true

  db_name  = var.master_db_name
  username = var.master_username
  password = random_password.rds_master.result

  db_subnet_group_name   = aws_db_subnet_group.munchgo.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = var.multi_az
  publicly_accessible = false
  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Performance Insights
  performance_insights_enabled = var.enable_performance_insights

  # Parameter group for PostgreSQL tuning
  parameter_group_name = aws_db_parameter_group.munchgo.name

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-postgres"
    Layer  = "Layer1-CloudFoundations"
    Module = "rds"
  })
}

resource "aws_db_parameter_group" "munchgo" {
  name_prefix = "${var.name_prefix}-munchgo-pg16-"
  family      = "postgres16"
  description = "MunchGo PostgreSQL 16 parameter group"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-pg-params"
    Layer  = "Layer1-CloudFoundations"
    Module = "rds"
  })

  lifecycle {
    create_before_destroy = true
  }
}
