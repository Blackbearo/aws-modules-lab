# ---------- plan role（PR 用，唯讀）----------
resource "aws_iam_role" "plan" {
  name = "gh-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:Blackbearo@212666090/aws-modules-lab@1314821300:pull_request"
        }
      }
    }]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name = "tfstate-dev-access"
  role = aws_iam_role.plan.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.tfstate.arn}/envs/dev/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.tfstate.arn
      },
    ]
  })
}

# ---------- apply role（environment:dev 用）----------
resource "aws_iam_role" "apply" {
  name = "gh-terraform-apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:Blackbearo@212666090/aws-modules-lab@1314821300:environment:dev"
        }
      }
    }]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_caller_identity" "current" {}

locals {
  # 對應 modules/vpc：name = "${var.env_name}-vpc-flow-logs-role"（dev、staging 共用）
  flow_logs_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-vpc-flow-logs-role"
}

resource "aws_iam_role_policy" "apply_access" {
  name = "tfapply-dev-access"
  role = aws_iam_role.apply.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAMForFlowLogsRole"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:TagRole",
          "iam:UntagRole",
        ]
        Resource = local.flow_logs_role_arn
      },
      {
        Sid       = "PassFlowLogsRole"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.flow_logs_role_arn
        Condition = { StringEquals = { "iam:PassedToService" = "vpc-flow-logs.amazonaws.com" } }
      },
      {
        Sid      = "ServiceLinkedRoles"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*"
      },
      {
        Sid      = "TerraformStateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.tfstate.arn}/envs/dev/*"
      },
      {
        Sid      = "TerraformStateBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.tfstate.arn
      },
    ]
  })
}
