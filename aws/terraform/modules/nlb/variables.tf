variable "project" { type = string }
variable "env" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "node_instance_ids" { type = list(string) }

variable "gatekeeper_instance_id" {
  description = "The single node placed in the :80 target group — the ACME endpoint."
  type        = string
}

variable "deletion_protection" {
  type    = bool
  default = true
}
