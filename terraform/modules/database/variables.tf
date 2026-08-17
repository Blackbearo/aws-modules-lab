variable "env_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "RDS 要住的 private subnet,通常來自 module.vpc.private_subnet_ids"
  type        = list(string)
}

variable "app_security_group_id" {
  description = "只有這個 SG(app 層)能連進來,通常來自 module.web_tier.app_sg_id"
  type        = string
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "multi_az" {
  description = "prod 建議開 true,dev/staging 可 false 省錢"
  type        = bool
  default     = false
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "vpc_cidr" {
  description = "VPC 網段,用於收窄 egress 規則"
  type        = string
}

