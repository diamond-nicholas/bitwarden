# Core deployment settings
variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "eu-west-1"
}

variable "name" {
  description = "Name prefix for resource names."
  type        = string
  default     = "bitwarden"
}

variable "environment" {
  description = "Environment name used in tags and naming."
  type        = string
  default     = "prod"
}

# Network settings
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet used by the NLB and NAT gateway."
  type        = string
  default     = "10.20.2.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet that hosts the EC2 instance and SSM endpoints."
  type        = string
  default     = "10.20.1.0/24"
}

# EC2 settings
variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.medium"
}

variable "instance_volume_size" {
  description = "Root EBS volume size in GB for the EC2 instance."
  type        = number
  default     = 30
}

variable "domain_name" {
  description = "Optional custom domain name for the public NLB."
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for the custom domain."
  type        = string
  default     = null
}
