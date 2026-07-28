# AWS 三層式架構 IaC

以 Terraform 從零建立可重複部署的 AWS 三層式架構。單一指令即可完成 24 個資源的建置與銷毀，全程約 10 分鐘。

---

## 架構

```
                Internet
                    │
                    ▼
        ┌───────────────────────┐
        │  ALB（public subnet） │  ← 唯一對外開放的一層（80）
        └───────────┬───────────┘
                    ▼
        ┌───────────────────────┐
        │ Tomcat / ASG          │  ← 8080 只接受 ALB 的 SG
        │（private subnet）     │     無公網 IP
        └───────────┬───────────┘
                    ▼
        ┌───────────────────────┐
        │ RDS PostgreSQL        │  ← 5432 只接受 app 層的 SG
        │（private subnet）     │
        └───────────────────────┘
```

跨兩個可用區（ap-northeast-1a / 1c）部署，ALB 負責流量分配與健康檢查，ASG 依 CPU 使用率自動擴縮。

---

## 設計重點

**Module 化，架構邏輯只寫一份**

拆為 `vpc`、`web-tier`、`database` 三個 module，環境層僅負責呼叫與傳參。新增環境時複製 `environments/` 底下的資料夾、調整參數即可，不需複製或修改任何架構邏輯，從結構上避免多環境設定長期偏移。

**縱深防禦：Security Group 引用 Security Group**

各層之間不以 IP 網段放行，而是引用上游的 SG ID，即「認身分不認位址」。ALB 之外的資源無公網 IP，Tomcat 僅接受來自 ALB 的流量，RDS 僅接受來自 app 層的流量。SSH 來源於 apply 時自動偵測當下對外 IP，避免浮動 IP 環境下的白名單失效問題。

**Remote State：S3 + 原生 locking**

State 存放於 S3 並啟用版本控制與加密，透過 S3 native locking 防止多人同時 apply 造成 state 損毀。團隊成員只需 clone repo 並設定 AWS 憑證即可接上同一份 state，無須手動傳遞檔案。

**參數與機密分離**

CIDR、規格、AMI ID 等屬架構設定，納入版控以維持單一真實來源；資料庫密碼隔離於 `secrets.auto.tfvars`，不進版控。

---

## 目錄結構

```
terraform/
  modules/              架構邏輯，多環境共用
    vpc/                VPC、subnet、IGW、路由表
    web-tier/           SG、ALB、Target Group、Launch Template、ASG
    database/           RDS、DB subnet group、SG
  environments/
    dev/                呼叫 module 並帶入 dev 參數
docs/                   設計與操作紀錄
```

---

## 使用方式

需求：Terraform 1.x、已設定 AWS 憑證、S3 bucket（存放 state）

```bash
cd terraform/environments/dev

# 建立 secrets.auto.tfvars，填入資料庫密碼
echo 'db_password = "your-password"' > secrets.auto.tfvars

terraform init
terraform plan
terraform apply

# 取得 ALB 網址
terraform output alb_dns
```

銷毀全部資源：

```bash
terraform destroy
```

詳細設計說明與操作紀錄見 [docs/](docs/)。

---

## 技術棧

Terraform · AWS（VPC / EC2 / ALB / Auto Scaling / RDS / S3）· PostgreSQL · Tomcat

---

## 後續規劃

- 擴充 staging / prod 環境（結構已預留，僅需調整參數）
- 導入 GitLab CI，變更經 MR review 與自動化 plan 驗證後方可套用
- 以 SSM Session Manager 取代跳板機，關閉對外 SSH 埠
- 資料庫密碼改由 AWS Secrets Manager 管理
