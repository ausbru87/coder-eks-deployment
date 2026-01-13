# RDS Module: PostgreSQL with Multi-AZ and PgBouncer

variable "name" {
  type    = string
  default = "coder-demo"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "vpc_cidr" {
  type = string
}

variable "db_credentials_secret_arn" {
  type = string
}

variable "instance_class" {
  type    = string
  default = "db.t3.small"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 100
}

data "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = var.db_credentials_secret_arn
}

locals {
  db_credentials = jsondecode(data.aws_secretsmanager_secret_version.db_credentials.secret_string)
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.name}-db-subnet-group"
  }
}

# RDS Security Group
resource "aws_security_group" "rds" {
  name_prefix = "${var.name}-rds-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "PostgreSQL from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-rds-sg"
  }
}

# Parameter Group (force SSL)
resource "aws_db_parameter_group" "main" {
  name   = "${var.name}-postgres17"
  family = "postgres17"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # Log queries > 1s
  }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier = "${var.name}-postgres"

  engine         = "postgres"
  engine_version = "17"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "coder"
  username = local.db_credentials.username
  password = local.db_credentials.password

  multi_az = true

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  publicly_accessible    = false

  parameter_group_name = aws_db_parameter_group.main.name

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final-snapshot"

  tags = {
    Name = "${var.name}-postgres"
  }
}

# Output connection URL (for Coder)
locals {
  db_connection_url = "postgres://${local.db_credentials.username}:${local.db_credentials.password}@${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}?sslmode=require"
}
