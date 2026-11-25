# Terraform CI/CD + OIDC 實作手冊

> 照順序做就能重現。所有 Console 按鈕名稱都是實際看到的字。

## 專案資訊

| 項目 | 值 |
|---|---|
| Repo | `Blackbearo/aws-modules-lab`（public） |
| 工作機 | AWS（OL10.2） |
| AWS provider | `~> 6.0`（dev 鎖 6.73.0） |
| AWS 帳號 | `575005867578` |
| Region | `ap-northeast-1` |
| State bucket | `luke-tfstate-2026` |
| Terraform | 1.10.5 |
| plan role | `arn:aws:iam::575005867578:role/gh-terraform-plan` |
| apply role | `arn:aws:iam::575005867578:role/gh-terraform-apply` |
| OIDC sub（plan） | `repo:Blackbearo@212666090/aws-modules-lab@1314821300:pull_request` |
| OIDC sub（apply） | `repo:Blackbearo@212666090/aws-modules-lab@1314821300:environment:dev` |

## 進度

| 階段 | 內容 | 狀態 |
|---|---|---|
| 0 | CI 前整備 | ✅ |
| 1 | OIDC + plan role | ✅ |
| 2 | plan pipeline | ✅ |
| 3 | 安全掃描（Trivy + Checkov） | ✅ Failed 33→0 |
| 4 | apply / destroy pipeline | ✅ ALB 回 200 |
| 5 | 後續強化（bootstrap、staging、釘 SHA、轉 public） | 🔄 drift detection 未做 |

---

# 踩坑速查

| 症狀 | 原因 | 解法 |
|---|---|---|
| `Request ARN is invalid` | role ARN 格式錯 | `arn:aws:iam::` 是**兩個冒號**（IAM 無 region） |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | trust policy 的 `sub` 對不上 | GitHub 現在用 **immutable subject claim**，格式是 `repo:<owner>@<id>/<repo>@<id>:<context>`，網路教學都是舊格式 |
| `Credentials could not be loaded` | 缺 `permissions: id-token: write` | 加上 |
| `Set up job` 就失敗 | workflow 定義錯（action 版本不存在等） | 看錯誤訊息，不用往下查 |
| `unable to find version 0.28.0` | trivy-action tag 不對 | 釘 commit SHA，行尾註解版本（`# v0.36.0`，**有 v 前綴**） |
| action 參數填 `''` | 空字串≠不指定 | 不指定就整行刪掉 |
| Checkov 過了但 Trivy 還是紅 | 兩者豁免語法不通用 | Checkov 用 `# checkov:skip=ID:理由`（區塊內），Trivy 用 `#trivy:ignore:ID 理由`（區塊上一行） |
| skip 寫了沒生效 | 寫在錯的資源上 | 看報告的 `FAILED for resource:` 指向誰就寫在誰身上 |
| Environment 沒有 Required reviewers 選項 | GitHub 方案限制 | Free/Pro/Team 的 private repo 都沒有；已轉 public 並開啟 |
| branch protection 說不會生效 | 同上 | 轉 public 後生效 || PR 永遠 merge 不了 | 勾了 `Require approvals` | 一個人不能核准自己的 PR，**不要勾** |
| `terraform fmt` 本機過 CI 沒過 | `-chdir` 只掃該目錄 | 在 **repo 根目錄**跑 |
| inline policy 建到獨立 policy 去了 | 從 `policy` 選單進去 | 要從 **role 詳細頁 → license 分頁 → New license ▾** 進 |
| 找不到 Run workflow 按鈕 | `workflow_dispatch` 只在 main 出現 | 先 merge 進 main |

---

# Console 用語對照

這個帳號的 Console 是機器翻譯，跟英文文件對不上。

| 官方 | 這裡顯示 |
|---|---|
| Identity providers | Identity Supplier |
| Add provider | New suppliers |
| Audience | object |
| Create role | **Create a character** |
| Custom trust policy | Customized Trust Policy |
| Add permissions | New license |
| Permissions policies | Licensing Policy |
| Attach existing policies | Use existing policy |
| Create inline policy | Establish embedded policies |
| Role name | Character Name |
| Permissions（分頁） | **license** |
| Trust relationships（分頁） | Trust relationship |
| Access Advisor（分頁） | Last access |
| Inline policy（類型） | Embedded by clients |
| Deactivate | **Discontinued** |

> 想避免這些，Console 右下角可切成 English。

---

# 階段 0：CI 前整備

## 0-1 設 GitHub Secret

`secrets.auto.tfvars` 被 gitignore 擋著，CI 拿不到，要另外給。

```
repo → Settings → Secrets and variables → Actions → New repository secret
Name:  DB_PASSWORD
Value: (dev 環境密碼)
```

## 0-2 確認 backend

`terraform/environments/dev/backend.tf`：

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

`use_lockfile = true` 是 S3 原生鎖（TF 1.10+），不需要 DynamoDB 鎖表。

## 0-3 本機驗證

**在 repo 根目錄跑 fmt**，不然只掃到 `environments/dev`，`modules/` 會漏掉。

```bash
cd ~/aws-modules-lab
terraform fmt -check -recursive
terraform -chdir=terraform/environments/dev init
terraform -chdir=terraform/environments/dev validate
```

有輸出檔名就跑 `terraform fmt -recursive` 修掉，然後單獨 commit：

```bash
git add -u && git commit -m "style: terraform fmt -recursive"
```

單獨 commit 是為了讓之後的 PR diff 乾淨，看的人不用從空白調整裡找真正的變更。

## 0-4 Git 認證改 SSH key

Token 會過期，而且推 `.github/workflows/` 需要額外勾 `workflow` 權限。SSH 沒這些問題。

```bash
ssh-keygen -t ed25519 -C "k8s-w1"     # 三次 Enter
cat ~/.ssh/id_ed25519.pub
```

貼到 `GitHub → Settings → SSH and GPG keys → New SSH key`，然後：

```bash
cd ~/aws-modules-lab
git remote set-url origin git@github.com:Blackbearo/aws-modules-lab.git
ssh -T git@github.com     # 出現 "Hi Blackbearo!" 就通了
```

公司防火牆擋 port 22 的話，`~/.ssh/config` 加：

```
Host github.com
  Hostname ssh.github.com
  Port 443
  User git
```

---

# 階段 1：OIDC + plan role

不用把 AWS 金鑰存進 GitHub。GitHub 每次執行時拿一張自己簽的身分證去換 AWS 的臨時憑證，1 小時到期。

## 1-1 建 Identity Provider

```
IAM → 左側「Identity Supplier」→ 右上「New suppliers」

Supplier type:  OpenID Connect
Supplier URL:   https://token.actions.githubusercontent.com
Audience(object): sts.amazonaws.com
```

Tags 不用加 → **New suppliers**。

沒有 thumbprint 欄位是正常的。

## 1-2 建 plan role

```
IAM → 左側「Role」→ 右上「Create a character」
Step 1: 選「Customized Trust Policy」
```

JSON 全部刪掉，貼入：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::575005867578:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:Blackbearo@212666090/aws-modules-lab@1314821300:pull_request"
        }
      }
    }
  ]
}
```

⚠️ **`sub` 一定要用 `StringEquals` 寫死，不能用萬用字元**——用萬用字元的話任何人開個 repo 都能拿你的憑證。

⚠️ **`sub` 裡的數字 ID 不能省**。網路教學寫的 `repo:owner/repo:pull_request` 是舊格式，會失敗。不確定自己的值，用下面的除錯法印出來。

底部要顯示 `Errors: 0`、`Security: 0` 才往下。

```
Step 2: 選「Use existing policy」→ 搜尋 ReadOnlyAccess
        勾「ReadOnlyAccess」（前後沒有其他字，在第 10 頁左右）
Step 3: Character Name = gh-terraform-plan → Create a character
```

## 1-3 補 inline policy

plan 要寫 S3 鎖檔，ReadOnlyAccess 不夠。

```
點進 gh-terraform-plan → 「license」分頁
→ 右上「New license ▾」→「Establish embedded policies」
→ 右上切到「JSON」（預設是 Visual，逐項點很痛苦）
```

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::luke-tfstate-2026/envs/dev/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::luke-tfstate-2026"
    }
  ]
}
```

名稱 `tfstate-dev-access`。

⚠️ 兩個 Resource 不一樣：上面有 `/envs/dev/*`（物件），下面沒有 `/*`（bucket 本身）。少一層會 AccessDenied。

## 1-4 驗收

```bash
aws iam get-role --role-name gh-terraform-plan \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
aws iam list-attached-role-policies --role-name gh-terraform-plan --output table
aws iam list-role-policies --role-name gh-terraform-plan --output table
```

## 附：查自己的 OIDC sub 實際值

assume 一直失敗時用這招。在 `configure-aws-credentials` **前面**插入：

```yaml
      - name: 印出 OIDC claim（除錯用，查完刪掉）
        run: |
          TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
          P=$(echo "$TOKEN" | cut -d. -f2)
          while [ $(( ${#P} % 4 )) -ne 0 ]; do P="${P}="; done
          echo "$P" | tr '_-' '/+' | base64 -d | jq '{sub, aud, repository, event_name}'
        working-directory: .
```

⚠️ 只印解碼後的欄位，**不要 `echo $TOKEN`**。查完刪掉。

更新 trust policy：

```bash
aws iam update-assume-role-policy \
  --role-name gh-terraform-plan --policy-document file:///tmp/trust.json
```

---

# 階段 2：plan pipeline

改 `.tf` → 開 PR → 自動跑 plan → 結果貼回 PR。

## `.github/workflows/terraform-plan.yml`

```yaml
name: terraform-plan

on:
  pull_request:
    paths:
      - 'terraform/**'
      - '.github/workflows/terraform-*.yml'

concurrency:
  group: tf-dev-${{ github.ref }}
  cancel-in-progress: true

permissions:
  id-token: write        # 沒這行拿不到 OIDC token
  contents: read
  pull-requests: write   # 為了貼留言

jobs:
  plan:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform/environments/dev
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: arn:aws:iam::575005867578:role/gh-terraform-plan
          aws-region: ap-northeast-1

      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_version: "1.10.5"
          terraform_wrapper: false

      - name: fmt
        run: terraform fmt -check -recursive
        working-directory: .          # 根目錄，才會掃到 modules/

      - name: init
        run: terraform init -input=false

      - name: Trivy config scan
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          scan-type: config
          scan-ref: terraform/
          severity: HIGH,CRITICAL
          exit-code: '1'

      - name: Checkov
        uses: bridgecrewio/checkov-action@b17b606d6ec72bb8ba5721ad5b7e340b80a9fc39 # v12.3142.0
        with:
          directory: terraform/
          framework: terraform
          soft_fail: false
          output_format: cli

      - name: validate
        run: terraform validate

      - name: plan
        id: plan
        continue-on-error: true
        env:
          TF_VAR_db_password: ${{ secrets.DB_PASSWORD }}
        run: |
          terraform plan -no-color -input=false -lock-timeout=5m | tee plan.txt
          echo "exitcode=${PIPESTATUS[0]}" >> "$GITHUB_OUTPUT"

      - name: 把 plan 貼回 PR
        uses: actions/github-script@ed597411d8f924073f98dfc5c65a23a2325f34cd # v8.0.0
        with:
          script: |
            const fs = require('fs');
            let body = fs.readFileSync(
              'terraform/environments/dev/plan.txt', 'utf8');
            if (body.length > 60000) {
              body = body.slice(0, 60000) + '\n\n...(過長已截斷，詳見 Actions log)';
            }
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '### Terraform Plan (dev)\n```hcl\n' + body + '\n```'
            });

      - name: plan 失敗就讓 job 紅掉
        if: steps.plan.outputs.exitcode != '0'
        run: exit 1
```

## 幾個寫法的理由

| 寫法 | 為什麼 |
|---|---|
| `permissions: id-token: write` | 預設不發 OIDC token，要顯式開 |
| `concurrency` | 連推兩個 commit 會有兩個 job 搶 S3 鎖 |
| plan 用 `continue-on-error` + 最後 `exit 1` | 失敗時錯誤訊息還是要貼回 PR，不然只看到紅叉 |
| `${PIPESTATUS[0]}` | 有 `\|` 的話 `$?` 拿到的是 `tee` 的結果，不是 terraform 的 |
| `terraform_wrapper: false` | 預設會包一層 wrapper 干擾輸出 |
| 釘版本 | 不釘的話某天自動升級跑出不同結果 |

## 測試

```bash
git checkout -b feat/add-ci
git add .github/ && git commit -m "ci: add terraform plan workflow with OIDC"
git push -u origin feat/add-ci
```

開 PR，PR 頁面應該出現 bot 留言貼著完整 plan。

---

# 階段 3：安全掃描

掃 `.tf` 檔看設定有沒有問題（不是掃 CVE，是掃「你的設定方式安不安全」）。

## 導入順序

1. 先設成不擋（Trivy `exit-code: '0'`、Checkov `soft_fail: true`）
2. 看清單、逐條處理
3. 全部處理完再改成擋（`'1'` / `false`）

一開始就設擋會卡住寸步難行。

## 本機掃描

```bash
sudo dnf install -y python3-pip
pip3 install checkov          # pip 21.x 沒有 --break-system-packages

cd ~/aws-modules-lab
checkov -d terraform/ --framework terraform --compact --quiet 2>/dev/null | tail -3

# 看失敗清單
checkov -d terraform/ --framework terraform --compact --quiet 2>/dev/null \
  | grep -B1 "FAILED for resource" | grep "^Check:" | sort | uniq -c | sort -rn
```

## 豁免寫法

**兩個工具語法不通用，要各寫一份。**

```hcl
#trivy:ignore:AWS-0164 public subnet 配公有 IP 是設計
resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:public subnet 配公有 IP 是設計
  ...
}
```

| | Checkov | Trivy |
|---|---|---|
| ID | `CKV_AWS_130` | `AWS-0164` |
| 語法 | `# checkov:skip=ID:理由` | `#trivy:ignore:ID 理由` |
| 位置 | 資源區塊**內** | 資源區塊**上一行** |

豁免一定要寫理由，一年後才知道是決策不是疏忽。

## 本專案的處置

**修掉**：egress 收窄成 VPC CIDR、egress 補 description、RDS 加密、強制 IMDSv2、ALB 丟棄非法 header、RDS 自動小版本升級、快照帶 tag、VPC Flow Logs、預設 SG 清空。

**豁免**：WAF（要錢）、Multi-AZ（雙倍成本）、deletion protection（lab 要能 destroy）、Performance Insights / Enhanced Monitoring / RDS log 匯出（都要錢）、public subnet 配公有 IP（設計）、ALB 對外開 80（設計）、bastion SG 沒掛資源（預期）、RDS IAM 認證（要改應用程式）。

**Backlog**：ALB HTTPS 四條（需 ACM 憑證+網域）、ALB access log（需 S3 bucket）。

結果：`Passed 40 → 70, Failed 33 → 0, Skipped 0 → 20`

## Trivy 的三條豁免

| 規則 | 資源 |
|---|---|
| `AWS-0164` | `aws_subnet.public` |
| `AWS-0053` | `aws_lb.this` |
| `AWS-0054` | `aws_lb_listener.http` |

---

# 階段 3 附錄：完整 .tf 檔

## `modules/vpc/variables.tf`

```hcl
variable "env_name" {
  description = "環境名稱,會加進資源的 Name tag,例如 dev、staging、prod"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 的網段,三環境須互不重疊"
  type        = string
}

variable "azs" {
  description = "要用的可用區,長度決定要開幾組 subnet"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "flow_log_retention_days" {
  description = "VPC Flow Log 在 CloudWatch 的保存天數。dev 設短以控制成本"
  type        = number
  default     = 30
}

variable "enable_nat" {
  description = "建 NAT Gateway（EKS node 在 private subnet 要出網）；dev 不開"
  type        = bool
  default     = false
}
```

## `modules/vpc/main.tf`

```hcl
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
```

## `modules/web-tier/variables.tf`

```hcl
variable "env_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC 網段,用於收窄 egress"
  type        = string
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
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "admin_cidrs" {
  description = "允許 SSH 的來源網段。空清單 = 不開 22 port"
  type        = list(string)
  default     = []
}
```

## `modules/web-tier/main.tf`

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_security_group" "bastion" {
  # checkov:skip=CKV2_AWS_5:admin_cidrs 為空時本 SG 無 ingress 也無掛載資源,僅供 app SG 引用
  name        = "${var.env_name}-sg-web"
  description = "bastion ssh"
  vpc_id      = var.vpc_id

  # admin_cidrs 為空 = 不產生 ingress，22 port 全關。
  # SG 本體要保留，因為 app SG 引用了它的 id。
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
  # checkov:skip=CKV_AWS_260:ALB 是對外入口,80 對 0.0.0.0/0 是設計
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

#trivy:ignore:AWS-0053 ALB 是對外服務入口,公開暴露是設計
resource "aws_lb" "this" {
  # checkov:skip=CKV2_AWS_28:dev 不開 WAF(約 $5/月);prod 必須掛
  # checkov:skip=CKV_AWS_150:lab 要能反覆 destroy,不開刪除保護;prod 必須開
  # checkov:skip=CKV_AWS_91:access log 需另建 S3 bucket,列 backlog
  # checkov:skip=CKV2_AWS_20:HTTP→HTTPS 轉導需先有 HTTPS listener,列 backlog
  name                       = "${var.env_name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true

  tags = { Name = "${var.env_name}-alb" }
}

resource "aws_lb_target_group" "tomcat" {
  # checkov:skip=CKV_AWS_378:ALB 到 target 是 VPC 內部流量;對外 HTTPS 需 ACM,列 backlog
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

#trivy:ignore:AWS-0054 HTTPS 需 ACM 憑證與網域,列 backlog
resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_2:HTTPS 需 ACM 憑證與網域,列 backlog
  # checkov:skip=CKV_AWS_103:同上
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

  # 強制 IMDSv2。IMDSv1 可無認證 GET 取得執行個體憑證,是 SSRF 竊取雲端憑證的路徑。
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
```

## `modules/database/variables.tf`（附加）

```hcl
variable "vpc_cidr" {
  description = "VPC 網段,用於收窄 egress"
  type        = string
}
```

## `modules/database/main.tf`

```hcl
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
  # checkov:skip=CKV_AWS_157:dev 單 AZ 省錢(Multi-AZ 雙倍費用);prod 必須開
  # checkov:skip=CKV_AWS_293:lab 要能反覆 destroy;prod 由 env_name 條件自動開
  # checkov:skip=CKV_AWS_353:Performance Insights 計費,dev 不開
  # checkov:skip=CKV_AWS_118:Enhanced Monitoring 計費,dev 不開
  # checkov:skip=CKV_AWS_129:RDS log 匯出計費,dev 不開
  # checkov:skip=CKV2_AWS_30:Query Logging 需自訂 parameter group 且計費
  # checkov:skip=CKV_AWS_161:IAM 認證需改應用程式連線方式,列 backlog
  identifier     = "${var.env_name}-pg"
  engine         = "postgres"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"

  # 加密只能在建立時決定，既有 RDS 無法補開，只能重建
  storage_encrypted = true

  db_name  = "appdb"
  username = "appadmin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  skip_final_snapshot = var.env_name == "prod" ? false : true
  deletion_protection = var.env_name == "prod" ? true : false

  tags = { Name = "${var.env_name}-pg" }
}
```

## `environments/dev/main.tf`（module 呼叫要補 vpc_cidr）

```hcl
module "web_tier" {
  # ...原有參數...
  vpc_cidr = var.vpc_cidr        # 新增
}

module "db" {
  # ...原有參數...
  vpc_cidr = var.vpc_cidr        # 新增
}
```

`environments/dev/variables.tf` 也要有 `admin_cidrs`（`default = []`）。

---

# 階段 4：apply / destroy pipeline

## 4-1 建 apply role

```
IAM → 「Role」→「Create a character」
Step 1: 選「Customized Trust Policy」
```

跟 plan role 只差 `sub` 結尾：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::575005867578:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:Blackbearo@212666090/aws-modules-lab@1314821300:environment:dev"
        }
      }
    }
  ]
}
```

| role | sub 結尾 |
|---|---|
| plan | `:pull_request` |
| apply | `:environment:dev` |

```
Step 2: 「Use existing policy」→ 勾 PowerUserAccess
Step 3: Character Name = gh-terraform-apply → Create a character
```

**不要用 AdministratorAccess**——這個 role 由 pipeline 自動使用，權限越大出事時範圍越大。

## 4-2 補 inline policy

`PowerUserAccess` 不含 IAM，但 VPC Flow Logs 要建 IAM role。

```
點進 gh-terraform-apply →「license」分頁
→「New license ▾」→「Establish embedded policies」→ 切「JSON」
```

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IAMForFlowLogsRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:TagRole", "iam:UntagRole", "iam:PassRole",
        "iam:CreateServiceLinkedRole"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformStateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::luke-tfstate-2026/envs/dev/*"
    },
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::luke-tfstate-2026"
    }
  ]
}
```

名稱 `tfapply-dev-access`。

⚠️ **一定要從 role 詳細頁進去**。從左側 `policy` 選單建的是獨立受管 policy，不是 inline。若誤建：

```bash
aws iam list-policies --scope Local --query "Policies[].{Name:PolicyName,Arn:Arn}" --output table
aws iam delete-policy --policy-arn arn:aws:iam::575005867578:policy/tfapply-dev-access
```

## 4-3 建 GitHub Environment

```
repo → Settings → Environments → New environment
Name: dev            ← 要跟 trust policy 的 sub 一字不差
```

```
✅ Required reviewers → 加自己        ← public repo 才有
❌ Prevent self-reviews                ← 單人 repo 勾了會無法 approve
```

environment 一定要建，因為 OIDC 的 `sub` 需要它存在。

鎖分支：

```
Deployment branches and tags → 右上「No restriction」下拉
→ 改「Selected branches and tags」→ Add rule → main
```

## 4-4 `.github/workflows/terraform-apply.yml`

```yaml
name: terraform-apply

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: '輸入 apply 以確認執行'
        required: true
        default: ''

concurrency:
  group: tf-dev-apply
  cancel-in-progress: false      # apply 中途被砍會讓 state 與現實脫節

permissions:
  id-token: write
  contents: read

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: dev             # OIDC sub 靠這行對應，不能拿掉
    defaults:
      run:
        working-directory: terraform/environments/dev
    steps:
      - name: 確認輸入
        if: inputs.confirm != 'apply'
        run: |
          echo "confirm 必須輸入 apply，收到：'${{ inputs.confirm }}'"
          exit 1

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: arn:aws:iam::575005867578:role/gh-terraform-apply
          aws-region: ap-northeast-1

      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_version: "1.10.5"
          terraform_wrapper: false

      - name: init
        run: terraform init -input=false

      - name: apply
        env:
          TF_VAR_db_password: ${{ secrets.DB_PASSWORD }}
        run: terraform apply -auto-approve -input=false -lock-timeout=10m

      - name: 輸出結果
        run: terraform output
```

## 4-5 `.github/workflows/terraform-destroy.yml`

```yaml
name: terraform-destroy

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: '輸入 destroy-dev 以確認銷毀（不可復原）'
        required: true
        default: ''

concurrency:
  group: tf-dev-apply           # 與 apply 共用，兩者不會同時跑
  cancel-in-progress: false

permissions:
  id-token: write
  contents: read

jobs:
  destroy:
    runs-on: ubuntu-latest
    environment: dev
    defaults:
      run:
        working-directory: terraform/environments/dev
    steps:
      - name: 確認輸入
        if: inputs.confirm != 'destroy-dev'
        run: |
          echo "confirm 必須輸入 destroy-dev，收到：'${{ inputs.confirm }}'"
          exit 1

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: arn:aws:iam::575005867578:role/gh-terraform-apply
          aws-region: ap-northeast-1

      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_version: "1.10.5"
          terraform_wrapper: false

      - name: init
        run: terraform init -input=false

      - name: destroy
        env:
          TF_VAR_db_password: ${{ secrets.DB_PASSWORD }}
        run: terraform destroy -auto-approve -input=false -lock-timeout=10m
```

確認字串刻意設成 `destroy-dev` 而非 `destroy`，要打出環境名稱才不會刪錯環境。

destroy 不用刪任何 `.tf`，它讀 state 反向刪除。程式碼還在，隨時能再 apply 建回來。

## 4-6 branch protection

```
Settings → Branches → Add branch protection rule
Branch name pattern: main

✅ Require a pull request before merging
   ❌ 不要勾 Require approvals      ← 一個人不能核准自己的 PR，勾了會鎖死
✅ Require status checks to pass → 勾 plan
✅ Do not allow bypassing the above settings
❌ Allow force pushes / Allow deletions
```

apply 的關卡：workflow_dispatch 打字確認 → Required reviewers 核准 → Deployment branches 限定 main。

## 4-7 執行

```
Actions → 左側選 terraform-apply → Run workflow
Branch: main → confirm 打 apply → Run workflow
```

約 10-15 分鐘（RDS 最慢）。

⚠️ `workflow_dispatch` 的按鈕**只在 main 出現**，要先 merge。

驗證：

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}" --output table
curl -I http://<ALB DNS>
```

實測結果：`HTTP/1.1 200` + `JSESSIONID`。

## 4-8 停用長期 Access Key

**先確認 destroy workflow 已經可用**，不然停用後清不掉環境。

這把 key 是給工作機用的，**跟 GitHub 無關**（GitHub 走 OIDC）。停用不影響 pipeline。

> ⚠️ `bootstrap/`、`environments/eks` 只能本機用 luke apply（CI role 沒有 IAM 權限），要用時才建 key；換工作機一律建新 key、刪舊 key。

```
IAM → IAM users → luke →「Security Certificates」分頁
→「Accessing the key」→ 右側「action ▼」→「Discontinued」
```

選 **Discontinued**（停用）不要選 `delete`。觀察一週再考慮刪除。

停用後：

| | |
|---|---|
| `aws` CLI | ❌ |
| 本機 terraform | ❌ |
| checkov 本機掃描 | ✅ |
| Console 登入 | ✅ |
| pipeline | ✅ |

---

# 階段 5：待辦

| 項目 | 說明 | 狀態 |
|---|---|---|
| IAM/OIDC 寫成 Terraform | `bootstrap/`（import 既有 bucket、OIDC、role，加 `prevent_destroy`）；管 CI 權限的東西不能由 CI apply | ✅ |
| 開 staging 環境 | `environments/staging`，同 module 換 tfvars + backend key | ✅ |
| module 改名不重建 | `moved.tf`：`module.database` → `module.db` | ✅ |
| AWS provider 6.x | `~> 5.0` → `~> 6.0`，plan 0 change | ✅ |
| action 釘 commit SHA | `@master` 最危險，trivy-action 曾遭供應鏈攻擊；SHA 後註解版本 | ✅ |
| action 升 Node 24 | checkout v7.0.1、aws v6.3.0、setup-terraform v4.0.1、github-script v8.0.0 | ✅ |
| 轉 public + Required reviewers | 先掃 Git 歷史無機敏值 | ✅ |
| EKS 環境 | `environments/eks`（社群 EKS module v21、vpc `enable_nat`），本機 apply | 🔄 |
| Drift detection | 排程跑 `terraform plan -detailed-exitcode`，有差異就開 issue | ⬜ |
| SSM Session Manager | 不開 22 port，走 AWS API 進去，自帶稽核 log | ⬜ |
| Secrets Manager | 密碼不經過 CI | ⬜ |
| 移植到 GitLab CI | `id_tokens` 拿 JWT + `aws sts assume-role-with-web-identity`，`when: manual` 當閘門 | ⬜ |
| ALB HTTPS | 需 ACM 憑證 + 網域 | ⬜ |
| ALB access log | 需另建 S3 bucket + policy | ⬜ |
| 收窄 IAM 權限 | role →「Last access」分頁 或「Policy generation」從 CloudTrail 產生 | ⬜ |

---

# 待驗證

`aws_security_group` 的 `ingress` 在 provider 裡是 Optional+Computed。`dynamic` 產出 0 個區塊時 = 屬性未設定，Terraform **不主張所有權**。

推論：break-glass 手動加的 22 port 規則，**apply 不會自動清掉**，要自己 revoke。

驗證方法：apply 後手動加一條 ingress，再跑 plan 看有沒有 diff。

---

# Break-glass：臨時開 SSH

```bash
MYIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id <sg-id> --protocol tcp --port 22 --cidr ${MYIP}/32

# 用完自己關（見上方待驗證，apply 可能不會幫你收）
aws ec2 revoke-security-group-ingress \
  --group-id <sg-id> --protocol tcp --port 22 --cidr ${MYIP}/32
```

查 SG ID：

```bash
aws ec2 describe-security-groups --filters "Name=group-name,Values=dev-*" \
  --query "SecurityGroups[].{Name:GroupName,Id:GroupId}" --output table
```
