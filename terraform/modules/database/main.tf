resource "aws_db_subnet_group" "this" {
  name       = "${var.env_name}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.env_name}-db-subnets" }
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
    description = "Outbound within VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.env_name}-sg-db" }
}

resource "aws_db_instance" "this" {
  # checkov:skip=CKV_AWS_157:dev 環境刻意單 AZ 以控制成本(Multi-AZ 為雙倍費用);prod 必須開啟
  # checkov:skip=CKV_AWS_293:lab 環境需可反覆 destroy,啟用刪除保護會造成阻礙;prod 由 env_name 條件自動開啟
  # checkov:skip=CKV_AWS_353:Performance Insights 計費,dev 不啟用
  # checkov:skip=CKV_AWS_118:Enhanced Monitoring 計費,dev 不啟用
  # checkov:skip=CKV_AWS_129:RDS log 匯出 CloudWatch 計費,dev 不啟用
  # checkov:skip=CKV2_AWS_30:Query Logging 需自訂 parameter group 且計費,dev 不啟用
  # checkov:skip=CKV_AWS_161:IAM 資料庫認證需變更應用程式連線方式,列入 backlog
  identifier     = "${var.env_name}-pg"
  engine         = "postgres"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"

  # CKV_AWS_16：靜態加密。零成本、零效能損失。
  # 重要:加密只能在「建立時」決定,既有執行個體無法補開,只能重建。
  storage_encrypted = true

  db_name  = "appdb"
  username = "appadmin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  auto_minor_version_upgrade = true # CKV_AWS_226
  copy_tags_to_snapshot      = true # CKV2_AWS_60

  # prod 環境務必評估開 deletion_protection,並移除 skip_final_snapshot
  skip_final_snapshot = var.env_name == "prod" ? false : true
  deletion_protection = var.env_name == "prod" ? true : false

  tags = { Name = "${var.env_name}-pg" }
}
