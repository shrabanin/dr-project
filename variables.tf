variable "aws_region" {
  default = "us-east-1"
}

variable "azs" {
  default = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  default = ["10.0.0.0/21", "10.0.8.0/21"]
}

variable "db_password" {
  description = "dbnew"
  type        = string
  sensitive   = true
}
