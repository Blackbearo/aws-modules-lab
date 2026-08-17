terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_security_group" "bastion" {
  # checkov:skip=CKV2_AWS_5:admin_cidrs 預設為空時本 SG 無 ingress 亦無掛載資源,為 D-2 的預期結果;僅供 app SG 引用
  name        = "${var.env_name}-sg-web"
  description = "bastion ssh"
  vpc_id      = var.vpc_id

  # admin_cidrs 為空清單時不產生任何 ingress，22 port 完全關閉。
  # SG 本體必須保留：aws_security_group.app 引用了它的 id。
  dynamic "ingress" {
    for_each = length(var.admin_cidrs) > 0 ? [1] : []
    content {
      description = "SSH from admin networks"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.admin_cidrs
    }
  }

  egress {
    description = "Outbound within VPC only (no NAT gateway present)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.env_name}-sg-web" }
}

resource "aws_security_group" "alb" {
  # checkov:skip=CKV_AWS_260:ALB 為對外服務入口,80 port 對 0.0.0.0/0 開放是設計本身
  name        = "${var.env_name}-sg-alb"
  description = "alb http from world"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from world"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound to app tier within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.env_name}-sg-alb" }
}

resource "aws_security_group" "app" {
  name        = "${var.env_name}-sg-app"
  description = "tomcat 8080 from alb, ssh from bastion"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Tomcat from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "Outbound within VPC only (RDS, internal services)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.env_name}-sg-app" }
}

resource "aws_lb" "this" {
  # checkov:skip=CKV2_AWS_28:dev 環境不啟用 WAF(約 $5/月 + 請求費);prod 必須掛 WAFv2
  # checkov:skip=CKV_AWS_150:lab 環境需可反覆 destroy,啟用刪除保護會造成阻礙;prod 必須開啟
  # checkov:skip=CKV_AWS_91:access log 需另建 S3 bucket 與 bucket policy,列入 backlog
  # checkov:skip=CKV2_AWS_20:HTTP→HTTPS 轉導需先有 HTTPS listener(需 ACM 憑證),列入 backlog
  name                       = "${var.env_name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true

  tags = { Name = "${var.env_name}-alb" }
}

resource "aws_lb_target_group" "tomcat" {
  # checkov:skip=CKV_AWS_378:ALB 至 target 為 VPC 內部流量;對外 HTTPS 需 ACM 憑證,列入 backlog
  name     = "${var.env_name}-tg-tomcat"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "${var.env_name}-tg-tomcat" }
}

resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_2:HTTPS 需 ACM 憑證與網域,屬獨立工程,列入 backlog
  # checkov:skip=CKV_AWS_103:同上,TLS 1.2 設定需先有 HTTPS listener
  # checkov:skip=CKV_AWS_378:同上
  # checkov:skip=CKV2_AWS_20:同上,HTTP→HTTPS 轉導需先有 HTTPS listener
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tomcat.arn
  }
}

resource "aws_launch_template" "tomcat" {
  name_prefix   = "${var.env_name}-tomcat-lt-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  # CKV_AWS_79：強制 IMDSv2。
  # IMDSv1 允許無認證的 GET 取得執行個體憑證,是 SSRF 竊取雲端憑證的經典路徑。
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.env_name}-asg-tomcat" }
  }
}

resource "aws_autoscaling_group" "tomcat" {
  name                = "${var.env_name}-asg"
  desired_capacity    = var.min_size
  min_size            = var.min_size
  max_size            = var.max_size
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.tomcat.arn]
  health_check_type   = "ELB"

  launch_template {
    id      = aws_launch_template.tomcat.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.env_name}-asg-tomcat"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu50" {
  name                   = "${var.env_name}-cpu-target-50"
  autoscaling_group_name = aws_autoscaling_group.tomcat.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}
