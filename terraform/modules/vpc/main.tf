resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.env_name}-vpc" }
}

# CKV2_AWS_12：VPC 預設 SG 不應允許任何流量。
# 此資源不會「建立」SG（AWS 自動產生），而是接管它並清空所有規則。
# 未宣告 ingress / egress 區塊 = 移除全部規則。
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.env_name}-sg-default-locked" }
}

#trivy:ignore:AWS-0164 public subnet 依定義供對外資源使用,自動配發公有 IP 為預期行為
resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:public subnet 依定義供對外資源使用,自動配發公有 IP 為預期行為
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.env_name}-public-${var.azs[count.index]}", "kubernetes.io/role/elb" = "1" }
}

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 11)
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.env_name}-private-${var.azs[count.index]}", "kubernetes.io/role/internal-elb" = "1" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.env_name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.env_name}-rt-public" }
}

# 注意:private route table 刻意不設 0.0.0.0/0 路由。
# 無 NAT Gateway = private subnet 無對外網路,亦即每月省下約 $32。
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.env_name}-rt-private" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------- VPC Flow Logs (CKV2_AWS_11) ----------

resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_158:dev 環境使用 CloudWatch 預設加密,KMS CMK 另計約 $1/月
  # checkov:skip=CKV_AWS_338:dev 環境保存 30 天即可,保存一年會顯著增加成本
  name              = "/aws/vpc-flow-logs/${var.env_name}"
  retention_in_days = var.flow_log_retention_days
  tags              = { Name = "${var.env_name}-flow-logs" }
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.env_name}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.env_name}-vpc-flow-logs-role" }
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.env_name}-vpc-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DescribeLogGroups"]
        Resource = aws_cloudwatch_log_group.flow_logs.arn
      }
    ]
  })
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
  tags                 = { Name = "${var.env_name}-flow-log" }
}

resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.env_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.env_name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}
