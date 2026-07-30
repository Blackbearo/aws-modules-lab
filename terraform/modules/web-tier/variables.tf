variable "env_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "auto_detect_ip" {
  description = "true 時自動偵測執行者的對外 IP 作為 SSH 白名單。僅建議 dev 使用，見下方說明"
  type        = bool
  default     = false
}

variable "ssh_allowed_cidrs" {
  description = "允許 SSH 的來源網段清單，auto_detect_ip 為 false 時使用。可填多組(公司出口、VPN 出口等)"
  type        = list(string)
  default     = []
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
  description = "允許 SSH 的來源網段。預設為空 = 不開放 22 port"
  type        = list(string)
  default     = []
}
