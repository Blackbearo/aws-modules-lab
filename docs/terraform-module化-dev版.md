# Terraform Module 化架構（dev 版）

> 專案：aws-modules-lab
> 狀態：**已驗證成功**，24 個資源建置完成，ALB 可正常回應
> 範圍：以 dev 說明 module 設計；staging 見第 9 節，EKS 環境（`environments/eks`）另見 `terraform-cicd-oidc-roadmap.md` 階段 5

---

## 1. 架構概觀

```
Internet
   │
   ▼
ALB（public subnet）
   │  只有這層對外開放 80
   ▼
Tomcat / ASG（private subnet）
   │  8080 只接受 ALB 的 SG
   ▼
RDS PostgreSQL（private subnet）
      5432 只接受 app 層的 SG
```

驗證結果：瀏覽器打 ALB 網址顯示 `Tomcat OK`，並回報 `Served by: ip-10-10-11-146`——該 IP 屬 private subnet 網段，代表機器本身無公網 IP，流量確實經 ALB 轉發，三層隔離生效。

---

## 2. 為什麼要 module 化

原本的寫法（aws-learning-lab）將所有資源寫死在同一層目錄，CIDR、命名、規格皆為常數。要新增環境時只能整包複製、手動改名，多份程式碼很快失去同步。

Module 化的做法是把架構邏輯抽成可重複呼叫的模板：

- **架構邏輯只寫一份**，置於 `modules/`
- **參數另外給**，置於 `environments/dev/terraform.tfvars`

即使目前只有 dev 一個環境，先用這個結構寫，之後要加環境時只需複製資料夾、改參數，不必重寫任何邏輯。

---

## 3. 目錄結構

```
terraform/
  modules/                     架構邏輯，未來多環境共用
    vpc/
      main.tf
      variables.tf
      outputs.tf
    database/
      main.tf
      variables.tf
      outputs.tf
    web-tier/
      main.tf
      variables.tf
      outputs.tf
  environments/
    dev/
      main.tf                  呼叫三個 module（vpc、web_tier、db）
      moved.tf                 module.database → module.db（改名不重建）
      variables.tf             宣告接受哪些變數
      terraform.tfvars         實際數值
      secrets.auto.tfvars      密碼（不進 Git）
      backend.tf               state 存放位置
      outputs.tf               對外輸出 ALB 網址等
    staging/                   同 dev 結構，換 tfvars 與 backend key
    eks/                       vpc（enable_nat = true）+ 社群 EKS module
  bootstrap/                   state bucket、OIDC、CI role（本機 apply，CI 不碰）
```

`modules/` 與 `environments/` 為平行資料夾，不可互相包含。

**判斷要改哪裡**：

- 調整規格等參數 → 改 `environments/dev/terraform.tfvars`
- 變更架構設計本身（新增 subnet、調整健康檢查規則）→ 改 `modules/`

---

## 4. Module：VPC

### `modules/vpc/variables.tf`

```hcl
variable "env_name" {
  description = "環境名稱，用於資源 Name tag"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 網段"
  type        = string
}

variable "azs" {
  description = "使用的可用區，長度決定 subnet 組數"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "enable_nat" {
  description = "建 NAT Gateway（EKS node 在 private subnet 要出網）；dev 不開"
  type        = bool
  default     = false
}
```

### `modules/vpc/main.tf`

```hcl
# ══════════════════════════════════════════
# VPC 本體
# ══════════════════════════════════════════
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true

  tags = {
    Name = "${var.env_name}-vpc"
  }
}

# ══════════════════════════════════════════
# Subnet
# public：對外服務用，自動配公網 IP
# private：內部服務用，無公網 IP
# cidrsubnet(10.10.0.0/16, 8, 1) → 10.10.1.0/24
# ══════════════════════════════════════════
resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.env_name}-public-${var.azs[count.index]}"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 11)
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.env_name}-private-${var.azs[count.index]}"
  }
}

# ══════════════════════════════════════════
# Internet Gateway：對外邊界路由器，免費
# ══════════════════════════════════════════
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.env_name}-igw"
  }
}

# ══════════════════════════════════════════
# 路由表
# public：0.0.0.0/0 指向 IGW，有這條才算 public
# private：只有 VPC 內部互通，天生隔離
# ══════════════════════════════════════════
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.env_name}-rt-public"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.env_name}-rt-private"
  }
}

# ══════════════════════════════════════════
# 路由表關聯：把 subnet 插進對應的路由表
# ══════════════════════════════════════════
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

# ══════════════════════════════════════════
# NAT 開關：enable_nat = true 才建（eks 用；dev 不開，每月省約 $32）
# count = 條件 ? 1 : 0，引用時寫 [0]
# ══════════════════════════════════════════
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
```

> 實際檔案另有 Flow Logs、預設 SG 鎖定、subnet `kubernetes.io/role/*` tag，完整內容見 `terraform-cicd-oidc-roadmap.md` 階段 3 附錄。

### `modules/vpc/outputs.tf`

```hcl
output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
```

---

## 5. Module：Web Tier

### `modules/web-tier/variables.tf`

```hcl
variable "env_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ami_id" {
  description = "Tomcat AMI ID"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 2
}
```

### `modules/web-tier/main.tf`

```hcl
# ══════════════════════════════════════════
# Provider：自動偵測對外 IP 需要 http provider
# ══════════════════════════════════════════
terraform {
  required_providers {
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# ══════════════════════════════════════════
# SSH 來源自動偵測
# 每次 plan/apply 都即時查詢當下對外 IP
# chomp() 去除結尾換行，否則 CIDR 格式錯誤
# ══════════════════════════════════════════
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# ══════════════════════════════════════════
# Security Group 三道防線
# bastion：22 只認自己的 IP
# alb    ：80 對全世界開放，唯一該對外的入口
# app    ：8080 只認 ALB、22 只認 bastion
#          SG 引用 SG，認身分不認 IP
# ══════════════════════════════════════════
resource "aws_security_group" "bastion" {
  name        = "${var.env_name}-sg-web"
  description = "bastion ssh"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from current IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
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

# ══════════════════════════════════════════
# ALB：託管版反向代理，住在 public subnet
# 相當於 nginx 的角色，但由 AWS 管理
# ══════════════════════════════════════════
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

# Target Group：會自動更新的後端名單 + 健康檢查
# ASG 開出來的機器會自動註冊進來
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

# Listener：聽 80 轉給 Target Group
# 相當於 nginx 的 server{} 區塊
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tomcat.arn
  }
}

# ══════════════════════════════════════════
# ASG：自我修復機群
# Launch Template 是生機器的配方
# ASG 宣告該維持幾台，死了補、多了收
# 機器住 private subnet，不直接暴露公網
# ══════════════════════════════════════════
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

  # ELB 健康檢查比 EC2 自身檢查更貼近「服務有沒有活著」
  health_check_type = "ELB"

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

# 恆溫器：CPU 平均超過 50% 就自動加機器
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
```

### `modules/web-tier/outputs.tf`

```hcl
output "alb_dns" {
  value = aws_lb.this.dns_name
}

output "app_sg_id" {
  value = aws_security_group.app.id
}
```

### 資源與 subnet 的對應

| 資源 | 所在 subnet | 原因 |
|---|---|---|
| ALB | public | 對外服務，需經 IGW 路由 |
| ASG（Tomcat） | private | 不直接暴露公網，僅接受 ALB 轉發 |

Security Group 不受此層影響。SG 以「規則本身允許誰連入」區分信任邊界，與資源位於哪個 subnet 是互相獨立的兩層機制。

---

## 6. Module：Database

### `modules/database/variables.tf`

```hcl
variable "env_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "RDS 所在的 private subnet，來自 module.vpc.private_subnet_ids"
  type        = list(string)
}

variable "app_security_group_id" {
  description = "僅此 SG（app 層）可連入，來自 module.web_tier.app_sg_id"
  type        = string
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_password" {
  type      = string
  sensitive = true
}
```

### `modules/database/main.tf`

```hcl
# ══════════════════════════════════════════
# DB Subnet Group：限定 RDS 只能住在 private subnet
# 本身免費，可常駐
# ══════════════════════════════════════════
resource "aws_db_subnet_group" "this" {
  name       = "${var.env_name}-db-subnets"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.env_name}-db-subnets"
  }
}

# ══════════════════════════════════════════
# SG：5432 只認 app 層，信任鏈最深處
# ══════════════════════════════════════════
resource "aws_security_group" "db" {
  name        = "${var.env_name}-sg-db"
  description = "postgres 5432 from app tier only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from app tier"
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

  tags = {
    Name = "${var.env_name}-sg-db"
  }
}

# ══════════════════════════════════════════
# RDS 本體
# publicly_accessible = false：不給公網位址
# skip_final_snapshot = true：練習用，刪除不留快照
#   → 日後 prod 須改 false，並開 deletion_protection
# ══════════════════════════════════════════
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
  multi_az               = false

  skip_final_snapshot = true

  tags = {
    Name = "${var.env_name}-pg"
  }
}
```

### `modules/database/outputs.tf`

```hcl
output "endpoint" {
  value = aws_db_instance.this.address
}

output "db_sg_id" {
  value = aws_security_group.db.id
}
```

---

## 7. environments/dev

### `main.tf`

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# module 之間傳值語法：module.<模組名>.<該模組的 output>
# VPC 先建好，輸出 subnet ID，此層接手轉交給其他 module

module "vpc" {
  source   = "../../modules/vpc"
  env_name = var.env_name
  vpc_cidr = var.vpc_cidr
}

module "web_tier" {
  source             = "../../modules/web-tier"
  env_name           = var.env_name
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  ami_id             = var.ami_id
  instance_type      = var.instance_type
  min_size           = var.min_size
  max_size           = var.max_size
}

module "db" {
  source                = "../../modules/database"
  env_name              = var.env_name
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnet_ids
  app_security_group_id = module.web_tier.app_sg_id
  instance_class        = var.db_instance_class
  db_password           = var.db_password
}
```

### `moved.tf`

```hcl
# module 名稱由 database 改為 db：只改 state 地址，RDS 不重建（plan 0 change）
moved {
  from = module.database
  to   = module.db
}
```

### `variables.tf`

```hcl
variable "env_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_password" {
  type      = string
  sensitive = true
}
```

**HCL 語法提醒**：單行區塊僅允許一個參數，例如 `variable "env_name" { type = string }`。兩個以上參數必須換行，否則出現 `Invalid single-argument block definition` 錯誤。

### `terraform.tfvars`

```hcl
env_name          = "dev"
vpc_cidr          = "10.10.0.0/16"
ami_id            = "ami-077a9e4b2ecb72df5"
instance_type     = "t3.micro"
min_size          = 1
max_size          = 2
db_instance_class = "db.t3.micro"
```

AMI 綁定 region，此 AMI 位於 ap-northeast-1，與 VPC 同區。

### `secrets.auto.tfvars`（不進 Git）

```hcl
db_password = "實際密碼"
```

Terraform 自動載入所有 `*.auto.tfvars`，無須額外指令或參數。

### `backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket       = "luke-tfstate-2026"
    key          = "envs/dev/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

### `outputs.tf`

```hcl
# output 需逐層往上傳：module 的 output 不會自動冒到環境層
output "alb_dns" {
  description = "瀏覽器打這個網址"
  value       = module.web_tier.alb_dns
}

output "rds_endpoint" {
  description = "psql -h 這個位址連線"
  value       = module.db.endpoint
}
```

---

## 8. S3 Backend

### 用途

Terraform 預設將 state 存於本機。缺點：團隊無法協作、兩人同時 apply 會互相覆蓋、本機檔案遺失即失去所有資源追蹤紀錄。

移至 S3 後 state 集中存放，並透過 S3 原生 locking 防止併發寫入。同事只需 `git clone` + `aws configure` + `terraform init`，即會自動接上同一份 state。

### bucket 必須手動建立

bucket 必須先存在，Terraform 才有地方寫入 state，因此不能由使用它的環境建立。先手動建立一次，之後由 `terraform/bootstrap/` 以 `import` 接管（加 `prevent_destroy`，只在本機 apply），新增環境不需再建。

**Console 設定**（介面若為機翻版，文字可能與英文原名不同；`Discontinued` 即 Disable）

| 設定項 | 值 |
|---|---|
| Region | ap-northeast-1 |
| Bucket type | General purpose |
| Bucket namespace | Global（預設值） |
| Bucket name | 全球唯一，僅小寫字母、數字、句點、連字號 |
| Object Ownership | ACLs disabled（預設值） |
| Block all public access | 全部勾選（預設值） |
| **Bucket Versioning** | **Enable（預設 Disable，唯一需手動更改的項目）** |
| Default encryption | SSE-S3（預設值） |
| Object Lock | Disable（預設值） |

**CLI 設定**

```bash
BUCKET=luke-tfstate-2026

aws s3api create-bucket \
  --bucket $BUCKET \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

aws s3api put-bucket-versioning \
  --bucket $BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket $BUCKET \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket $BUCKET \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### Locking

`use_lockfile = true` 啟用 S3 原生 state locking。某人執行 apply 時，其他人的指令會被擋下並顯示 state 已鎖定。

此為 AWS 目前建議做法，不再需要另建 DynamoDB 資料表（舊版教學常見的 `dynamodb_table` 參數已非必要）。

---

## 9. 新增 staging / prod 的方式

staging 已依此流程建立（`environments/staging`，10.20.0.0/16，apply 29 個資源驗證後 destroy）。新增環境只需：

1. 複製整個 `environments/dev/` 為 `environments/staging/`
2. 改 `terraform.tfvars`：`env_name` 改為 `staging`、`vpc_cidr` 改為不重疊網段（例如 10.20.0.0/16）、規格視需要調整
3. 改 `secrets.auto.tfvars` 的密碼
4. 改 `backend.tf` 的 `key` 為 `envs/staging/terraform.tfstate`

`main.tf`、`variables.tf`、`modules/` **完全不動**。

三環境網段規劃建議：dev 10.10.0.0/16、staging 10.20.0.0/16、prod 10.30.0.0/16。互不重疊，避免日後 VPN 或 Direct Connect 互通時撞號。

**複製資料夾時最容易漏改的是 `backend.tf` 的 `key`。** 三環境若共用同一份 state，在 dev 執行 apply 時 Terraform 會認定 state 中記錄的 prod 資源不應存在而將其刪除。

屆時需額外考量（現在不必處理）：

- SSH 白名單改為固定 IP。正式環境不應使用自動偵測，否則防火牆規則會隨執行者位置變動；CI/CD 執行時更會抓到 Runner 的 IP
- prod 資料庫啟用 `multi_az`、`deletion_protection`，關閉 `skip_final_snapshot`
- IAM 權限分級，限制誰能對 prod 執行 apply
- 密碼改由 AWS Secrets Manager 管理

---

## 10. 版本控制與推上 GitHub

### 檔案存放位置

本文件建議放在 repo 內的 `docs/` 目錄，與程式碼一起版控：

```
aws-modules-lab/
  .gitignore
  README.md                          給他人看的專案說明
  docs/
    terraform-module化-dev版.md      本文件，操作與設計紀錄
    terraform-cicd-oidc-roadmap.md   CI/CD + OIDC 實作手冊
  .github/workflows/                 plan / apply / destroy
  terraform/
    bootstrap/
    modules/
    environments/
```

改架構時順手更新文件，文件才不會過期。

### `.gitignore`

**務必在 `git add` 之前建立**，否則 state 與密碼會被納入追蹤。

```bash
cd /root/aws-modules-lab

cat > .gitignore << 'EOF'
# Terraform 本機快取
.terraform/

# State 檔（存在 S3，不進版控）
*.tfstate
*.tfstate.*

# 機密（密碼等）
*.auto.tfvars

# 當機記錄
crash.log
crash.*.log

# 覆寫用的本機設定
override.tf
override.tf.json
*_override.tf
*_override.tf.json
EOF
```

### 哪些檔案進版控

| 檔案 | 進 Git | 原因 |
|---|---|---|
| `modules/**/*.tf` | 是 | 架構邏輯本體 |
| `environments/*/main.tf`、`variables.tf`、`outputs.tf` | 是 | 環境層呼叫結構 |
| `environments/*/terraform.tfvars` | 是 | CIDR、規格、AMI ID 屬架構設定，非機密。不進版控會導致設定缺乏單一真實來源，同事 clone 後無從得知應填何值 |
| `environments/*/backend.tf` | 是 | 僅 bucket 名稱與 key，不含機密 |
| `.terraform.lock.hcl` | **是** | 記錄 provider 確切版本與雜湊值，確保團隊成員與 CI 安裝到相同版本 |
| `environments/*/secrets.auto.tfvars` | **否** | 密碼 |
| `.terraform/`、`*.tfstate*` | 否 | 本機快取與狀態檔 |

### 初始化與推送

```bash
cd /root/aws-modules-lab

git init
git status --short          # 先確認清單，再 add
```

`git status` 應**看得到** `.tf` 檔、`terraform.tfvars`、`.terraform.lock.hcl`、`.gitignore`；
應**看不到** `secrets.auto.tfvars`、`*.tfstate`、`.terraform/`。

推送前掃描敏感值：

```bash
grep -rn "575005867578" --include="*.tf*" .    # AWS 帳號 ID
grep -rn "password" --include="*.tf" .          # 應只有變數宣告與 var. 引用
```

確認無誤後：

```bash
git config --global user.name "你的名字"
git config --global user.email "你的email"

git add .
git commit -m "Initial commit: AWS three-tier architecture with Terraform modules"

git remote add origin https://github.com/你的帳號/aws-terraform-lab.git
git branch -M main
git push -u origin main
```

### 若密碼曾經進過 commit

`.gitignore` 只擋尚未被追蹤的檔案。已納入追蹤者需另行移除：

```bash
git rm --cached -r .terraform
git rm --cached '*.tfstate*'
git rm --cached secrets.auto.tfvars
```

但若密碼已存在於某次 commit，即使後續刪除，**Git 歷史仍保留該內容**，推上公開 repo 等同外洩。此情況最乾淨的處理方式是重建歷史：

```bash
rm -rf .git
git init
git add .
git commit -m "Initial commit"
```

### 日常 Git 操作

```bash
git status                  # 看有哪些變更
git diff                    # 看變更內容
git add .
git commit -m "說明改了什麼"
git push

git log --oneline           # 看提交歷史
```

建議每完成一個階段就 commit 一次（例如「新增 database module」「調整 ASG 擴縮政策」），避免一次塞入大量變更，日後難以追溯。

---

## 11. 常用指令

### 日常操作

```bash
cd /root/aws-modules-lab/terraform/environments/dev

terraform init                 # 初始化，改過 module 或 backend 後要重跑
terraform fmt                  # 自動排版
terraform validate             # 語法檢查，不連 AWS
terraform plan                 # 預覽變更，不會實際建立
terraform apply                # 執行，需輸入 yes 確認
terraform destroy              # 刪除全部資源，需輸入 yes 確認
```

### 查詢

```bash
terraform output               # 列出所有輸出
terraform output alb_dns       # 只取 ALB 網址
terraform state list           # 列出 state 中所有資源
terraform state show module.vpc.aws_vpc.this   # 看單一資源的完整屬性
terraform providers            # 列出使用的 provider 與版本
```

### 進階

```bash
terraform plan -out=tfplan     # 存下 plan，確保 apply 時執行的與預覽完全一致
terraform apply tfplan         # 套用已存的 plan，不會再問 yes

terraform apply -target=module.vpc      # 只套用特定 module（除錯用，平時避免）
terraform destroy -target=module.db   # 只刪特定 module

terraform refresh              # 以實際 AWS 現況更新 state
terraform show                 # 顯示目前 state 的完整內容
```

### S3 state 檢查

```bash
aws s3 ls s3://luke-tfstate-2026/envs/dev/          # 確認 state 存在
aws s3api list-object-versions \
  --bucket luke-tfstate-2026 \
  --prefix envs/dev/terraform.tfstate                # 看 state 歷史版本
```

### 常見情境

```bash
# 忘記密碼變數時臨時帶入
terraform apply -var="db_password=xxx"

# 鎖沒正常釋放（前次執行被中斷）時強制解鎖，LOCK_ID 從錯誤訊息取得
terraform force-unlock LOCK_ID

# 只想看某個 module 會建什麼
terraform plan -target=module.web_tier
```

---

## 12. 注意事項

- `modules/` 與 `environments/` 須為平行資料夾，不可互相包含。
- `main.tf` 中宣告的每個 `module` 區塊，對應的 `modules/` 資料夾都必須存在，否則 `terraform init` 出現 `Unreadable module directory` 錯誤。尚未建立的 module 不要寫入 `main.tf`。
- HCL 單行區塊僅允許一個參數，兩個以上須換行。
- module 的 output 不會自動傳到環境層，需在 `environments/dev/outputs.tf` 再輸出一次。
- state bucket 由 `bootstrap/` 管理（本機 apply），不可由使用它的環境或 CI 管理。
- 資料庫密碼不得寫入 `terraform.tfvars`（該檔需進版控），應另存於 `secrets.auto.tfvars`。
- **ALB 與 RDS 為持續計費資源，練習結束務必 `terraform destroy`。**
- 修改 SG 的 `description` 會觸發資源重建（`# forces replacement`），若該 SG 被其他 SG 引用，可能因 `DependencyViolation` 而刪除失敗。plan 中看到 `-/+` 或 `forces replacement` 必須停下確認。

---

## 13. 完成紀錄

| 項目 | 狀態 |
|---|---|
| 目錄結構（`modules/` 與 `environments/` 平行） | 完成 |
| S3 bucket 建立（luke-tfstate-2026） | 完成 |
| backend 接通 S3，state 遠端存放 | 完成 |
| `modules/vpc/` | 完成 |
| `modules/web-tier/` | 完成 |
| `modules/database/` | 完成 |
| `terraform apply` 24 個資源建置成功 | 完成 |
| ALB 回應驗證（Tomcat OK，由 private IP 提供服務） | 完成 |
| output 逐層輸出（alb_dns、rds_endpoint） | 完成 |
| `bootstrap/` import state bucket、OIDC、CI role | 完成 |
| `environments/staging/`（29 個資源 apply / destroy 驗證） | 完成 |
| `moved.tf`：`module.database` → `module.db`（RDS 不重建） | 完成 |
| AWS provider `~> 5.0` → `~> 6.0`（plan 0 change） | 完成 |
| GitHub Actions plan / apply / destroy（OIDC） | 完成 |
| vpc `enable_nat` 開關（`count`，dev 不開）與 subnet `kubernetes.io` tag | 完成 |
| `environments/eks/` | 進行中 |

### 後續可擴充項目

- `environments/prod/`
- Redis（ElastiCache）module
- bastion EC2 本體（目前僅建立 SG，尚無跳板機可 SSH 進 private subnet）
- RDS 等高費用資源的 `count` 開關
- IAM 權限分級
- GitLab CI 自動 plan / apply
- SSM Session Manager 取代跳板機
