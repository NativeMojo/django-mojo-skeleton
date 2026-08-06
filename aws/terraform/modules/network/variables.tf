variable "project" { type = string }
variable "env" { type = string }
variable "region" { type = string }
variable "vpc_cidr" { type = string }
variable "az_count" { type = number }

variable "admin_cidrs" {
  description = "Source CIDRs allowed to reach SSH on the nodes."
  type        = list(string)
}
