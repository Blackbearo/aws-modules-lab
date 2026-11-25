terraform {
  backend "s3" {
    bucket       = "luke-tfstate-2026"
    key          = "envs/eks/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
