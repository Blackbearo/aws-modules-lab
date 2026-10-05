resource "aws_s3_bucket" "tfstate" {
  # checkov:skip=CKV_AWS_145:SSE-S3 已足夠(同 Trivy AWS-0132),CMK 需額外費用且所有 role 要補 KMS 權限
  # checkov:skip=CKV_AWS_144:跨區複寫需另一 region 的 bucket,費用加倍;誤刪已有 versioning 可救
  # checkov:skip=CKV_AWS_18:access log 需另建 log bucket,列入 backlog
  # checkov:skip=CKV2_AWS_62:無服務需接收 state bucket 事件通知
  bucket = "luke-tfstate-2026"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AWS-0132 SSE-S3 已足夠：已 block public 且僅 CI role 可存取；CMK 需額外費用且所有 role 要補 KMS 權限
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    # 舊版 state：超過 90 天且不在最新 10 版內才刪
    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    # use_lockfile 每次刪 .tflock 會留下 delete marker，自動清掉
    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
