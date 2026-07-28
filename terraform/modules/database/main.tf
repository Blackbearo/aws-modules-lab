resource "aws_db_subnet_group" "this" {
  name       = "${var.env_name}-db-subnets"
  subnet_ids = var.subnet_ids
  tags = { Name = "${var.env_name}-db-subnets" }
}

resource "aws_security_group" "db" {
  name        = "${var.env_name}-sg-db"
  description = "postgres: 5432 only from app tier"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from app only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.app_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_name}-sg-db" }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.env_name}-pg"
  engine         = "postgres"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "appdb"
  username = "appadmin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az                = var.multi_az

  # prod 環境務必評估開 deletion_protection,並移除 skip_final_snapshot
  skip_final_snapshot = var.env_name == "prod" ? false : true
  deletion_protection = var.env_name == "prod" ? true : false

  tags = { Name = "${var.env_name}-pg" }
}
