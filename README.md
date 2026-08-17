# AWS 三層式架構 IaC

以 Terraform 建立可重複部署的 AWS 三層式架構，並透過 GitHub Actions 完成從變更審查到套用的完整流程。所有基礎設施變更皆經 PR 自動驗證、安全掃描與人工確認後由 pipeline 執行，本機與 CI 環境皆不存放任何長期 AWS 金鑰。

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
        │（private subnet）     │     靜態加密
        └───────────────────────┘
```

跨兩個可用區（ap-northeast-1a / 1c）部署，ALB 負責流量分配與健康檢查，ASG 依 CPU 使用率自動擴縮。全域啟用 VPC Flow Logs，預設 Security Group 規則清空。

---

## CI/CD

```
改 .tf → 開 PR
   ├─ OIDC 換發 1 小時臨時憑證
   ├─ fmt / validate
   ├─ Trivy + Checkov 安全掃描（不通過即擋住 merge）
   └─ terraform plan，結果自動貼回 PR
        ↓ 全綠才能 merge
   手動觸發 + 輸入確認字串
        ↓
   pipeline 執行 apply / destroy
```

| Workflow | 觸發 | 用途 |
|---|---|---|
| `terraform-plan` | PR（自動） | 格式、語法、安全掃描、plan 預演並回貼 PR |
| `terraform-apply` | 手動 + 輸入 `apply` | 建立 / 更新資源 |
| `terraform-destroy` | 手動 + 輸入 `destroy-dev` | 銷毀環境 |

**憑證採 OIDC 短期換發。** GitHub Actions 執行時向 AWS 出示由 GitHub 簽發的身分憑證，換取一小時後自動失效的臨時憑證。AWS 端以 trust policy 限定僅特定 repo 的特定觸發事件可換發，因此 CI 環境中不存在任何可長期使用的 AWS 金鑰。

**安全掃描具阻擋力，而非僅供參考。** Trivy 與 Checkov 於 plan 階段掃描 `.tf` 檔，HIGH/CRITICAL 未處理即無法 merge。每一項豁免皆於程式碼中以註解記錄規則 ID 與理由，區分「刻意的成本取捨」與「尚未處理的疏漏」。

---

## 設計重點

**Module 化，架構邏輯只寫一份**

拆為 `vpc`、`web-tier`、`database` 三個 module，環境層僅負責呼叫與傳參。新增環境時複製 `environments/` 底下的資料夾、調整參數即可，不需複製或修改任何架構邏輯，從結構上避免多環境設定長期偏移。

**縱深防禦：Security Group 引用 Security Group**

各層之間不以 IP 網段放行，而是引用上游的 SG ID，即「認身分不認位址」。ALB 之外的資源無公網 IP，Tomcat 僅接受來自 ALB 的流量，RDS 僅接受來自 app 層的流量。

對外 SSH 預設完全關閉（`admin_cidrs` 預設為空清單即不產生 22 port 規則），需要時以 break-glass 方式臨時開放並於使用後撤除。egress 亦收窄至 VPC 網段，不採用預設的全開設定。

**基礎設施定義不依賴執行環境**

同一份程式碼在任何機器執行都應產生相同結果。因此不使用動態偵測執行者對外 IP 一類的作法——該類寫法在單人單機環境可運作，但在 CI 中會將 runner 的隨機 IP 寫入 Security Group。所有來源網段改由變數顯式指定。

**Remote State：S3 + 原生 locking**

State 存放於 S3 並啟用版本控制與加密，透過 S3 native locking 防止同時 apply 造成 state 損毀。團隊成員只需 clone repo 即可接上同一份 state，無須手動傳遞檔案。

**參數與機密分離**

CIDR、規格、AMI ID 等屬架構設定，納入版控以維持單一真實來源；資料庫密碼隔離於 `secrets.auto.tfvars` 不進版控，CI 端則以 GitHub Secret 注入。

---

## 目錄結構

```
.github/workflows/
  terraform-plan.yml      PR 觸發：驗證、掃描、plan
  terraform-apply.yml     手動觸發：套用變更
  terraform-destroy.yml   手動觸發：銷毀環境

terraform/
  modules/              架構邏輯，多環境共用
    vpc/                VPC、subnet、IGW、路由表、Flow Logs
    web-tier/           SG、ALB、Target Group、Launch Template、ASG
    database/           RDS、DB subnet group、SG
  environments/
    dev/                呼叫 module 並帶入 dev 參數

docs/                   設計、實作與決策紀錄
```

---

## 使用方式

### 一般變更（建議路徑）

```bash
git checkout -b feat/your-change
# 修改 terraform/ 底下的檔案
git commit -am "feat: your change"
git push -u origin feat/your-change
```

開 PR 後 CI 自動執行驗證與掃描，plan 結果會貼回 PR。確認無誤後 merge，再至 **Actions → terraform-apply → Run workflow**，於 `confirm` 欄位輸入 `apply` 執行。

銷毀環境：**Actions → terraform-destroy → Run workflow**，輸入 `destroy-dev`。

### 本機驗證

```bash
cd ~/aws-modules-lab
terraform fmt -check -recursive                     # 在 repo 根目錄執行
terraform -chdir=terraform/environments/dev validate
checkov -d terraform/ --framework terraform --compact --quiet
```

以上皆不需 AWS 憑證。需執行 `plan` 時才需憑證，但一般情況交由 CI 處理即可。

---

## 技術棧

Terraform · AWS（VPC / EC2 / ALB / Auto Scaling / RDS / S3 / IAM / CloudWatch）· GitHub Actions · OIDC · Trivy · Checkov · PostgreSQL · Tomcat

---

## 後續規劃

- **Drift detection**：排程執行 `plan -detailed-exitcode`，偵測到與 state 不一致即自動開立 issue
- **SSM Session Manager**：取代跳板機，完全關閉對外 SSH 埠並取得完整操作稽核紀錄
- **Secrets Manager**：資料庫密碼改由 AWS Secrets Manager 管理，不再經過 CI
- **IAM 與 OIDC 資源納入 Terraform**：置於獨立的 `bootstrap/` 目錄
- **擴充 staging / prod 環境**：結構已預留，僅需調整參數
- **ALB HTTPS**：需 ACM 憑證與網域
- **收窄 IAM 權限**：依 Access Advisor 與 CloudTrail 實際使用紀錄取代目前較寬的受管 policy
- **GitHub Action 釘選至 commit SHA**：避免第三方 action 遭竄改造成供應鏈風險
- **移植至 GitLab CI**：概念相同，改以 `id_tokens` 換發憑證、`when: manual` 作為人工閘門

---

詳細實作步驟、決策紀錄與踩坑整理見 [docs/terraform-cicd-oidc-roadmap.md](docs/terraform-cicd-oidc-roadmap.md)。
