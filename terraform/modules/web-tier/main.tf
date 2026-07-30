terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

resource "aws_security_group" "bastion" {
  name        = "${var.env_name}-sg-web"
  description = "bastion ssh"
  vpc_id      = var.vpc_id

  # admin_cidrs 為空清單時不產生任何 ingress，22 port 完全關閉。
  # SG 本體必須保留：aws_security_group.app 引用了它的 id。
  # 需要臨時 SSH 時走 break-glass，下次 apply 會自動清掉。
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.env_name}-sg-web"
  }
}

resource "aws_security_group" "alb" {
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.env_name}-sg-alb"
  }
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.env_name}-sg-app"
  }
}

resource "aws_lb" "this" {
  name               = "${var.env_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = {
    Name = "${var.env_name}-alb"
  }
}

resource "aws_lb_target_group" "tomcat" {
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

  tags = {
    Name = "${var.env_name}-tg-tomcat"
  }
}

resource "aws_lb_listener" "http" {
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

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.env_name}-asg-tomcat"
    }
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
