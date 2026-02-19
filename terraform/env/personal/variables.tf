variable "vpc_name" {}
variable "vpc_cidr" {}

variable "azs" {
  type = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "ecr_name" {}

variable "instance_type" {}
variable "key_name" {}

variable "db_username" {
  description = "DB 사용자명"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "DB 비밀번호"
  type        = string
  sensitive   = true
}

variable "db_root_password" {
  description = "DB root 비밀번호"
  type        = string
  sensitive   = true
}
