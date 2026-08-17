variable "env_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC 網段,用於收窄 egress 規則"
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
  description = "允許 SSH 進 bastion 的來源網段。空清單 = 不建立 22 port 規則(見 D-2)"
  type        = list(string)
  default     = []
}
