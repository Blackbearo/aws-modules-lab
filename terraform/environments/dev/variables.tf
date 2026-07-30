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

variable "admin_cidrs" {
  description = "允許 SSH 進 bastion 的來源網段。空清單 = 不開放 22 port"
  type        = list(string)
  default     = []
}
