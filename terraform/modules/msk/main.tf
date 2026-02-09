# MunchGo Microservices - Amazon MSK (Managed Streaming for Apache Kafka)
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# LAYER 1: Cloud Foundations
# Provides event-driven messaging infrastructure for MunchGo microservices.
# Services use the Transactional Outbox pattern to publish domain events to Kafka.
#
# Topics (auto-created by services):
#   user-events, consumer-events, restaurant-events, courier-events,
#   order-events, saga-commands, saga-replies
#
# Communication pattern:
#   Service → Outbox table → OutboxRelay → Kafka → Consumer service

# ==============================================================================
# MSK CONFIGURATION
# ==============================================================================

resource "aws_msk_configuration" "munchgo" {
  name              = "${var.name_prefix}-munchgo-kafka-config"
  kafka_versions    = [var.kafka_version]
  description       = "MunchGo microservices Kafka configuration"

  server_properties = <<PROPERTIES
auto.create.topics.enable=true
num.partitions=3
default.replication.factor=2
min.insync.replicas=1
log.retention.hours=168
log.retention.bytes=1073741824
message.max.bytes=1048576
unclean.leader.election.enable=false
PROPERTIES
}

# ==============================================================================
# SECURITY GROUP
# ==============================================================================

resource "aws_security_group" "msk" {
  name_prefix = "${var.name_prefix}-msk-"
  vpc_id      = var.vpc_id
  description = "Security group for MSK cluster - MunchGo event messaging"

  # Allow Kafka plaintext from EKS nodes
  ingress {
    description     = "Kafka plaintext from EKS"
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  # Allow Kafka TLS from EKS nodes
  ingress {
    description     = "Kafka TLS from EKS"
    from_port       = 9094
    to_port         = 9094
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  # Allow Kafka IAM auth from EKS nodes
  ingress {
    description     = "Kafka IAM auth from EKS"
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  # Allow ZooKeeper from EKS nodes
  ingress {
    description     = "ZooKeeper from EKS"
    from_port       = 2181
    to_port         = 2181
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
    Name   = "${var.name_prefix}-msk-sg"
    Layer  = "Layer1-CloudFoundations"
    Module = "msk"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================================================
# MSK CLUSTER
# ==============================================================================

resource "aws_msk_cluster" "munchgo" {
  cluster_name           = "${var.name_prefix}-munchgo-kafka"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.broker_count

  broker_node_group_info {
    instance_type  = var.instance_type
    client_subnets = var.private_subnet_ids

    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.ebs_volume_size
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.munchgo.arn
    revision = aws_msk_configuration.munchgo.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT" # Allow both for dev; use TLS in prod
      in_cluster    = true
    }
  }

  # CloudWatch monitoring
  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true
      }
      node_exporter {
        enabled_in_broker = true
      }
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = var.enable_cloudwatch_logs
        log_group = var.enable_cloudwatch_logs ? aws_cloudwatch_log_group.msk[0].name : ""
      }
    }
  }

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-munchgo-kafka"
    Layer  = "Layer1-CloudFoundations"
    Module = "msk"
  })
}

# CloudWatch Log Group for MSK broker logs
resource "aws_cloudwatch_log_group" "msk" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = "/aws/msk/${var.name_prefix}-munchgo-kafka"
  retention_in_days = 7

  tags = merge(var.tags, {
    Name   = "${var.name_prefix}-msk-logs"
    Layer  = "Layer1-CloudFoundations"
    Module = "msk"
  })
}
