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
