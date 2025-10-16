variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI ID to use for instances (e.g., ami-0abcdef1234567890)"
  type        = string
  default     = "ami-0fd3ac4abb734302a"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "m6i.4xlarge"
}

variable "availability_zone" {
  description = "Availability Zone (e.g., us-east-1a)"
  type        = string
  default     = "us-east-1a"
}

variable "subnet_id" {
  description = "Subnet ID where instances will be launched"
  type        = string
  default     = "subnet-xxxx"
}

variable "key_name_default" {
  description = "Default EC2 key pair name (used unless overridden per instance)"
  type        = string
  default     = "changeme"
}

variable "num_instances" {
  description = "How many EC2 instances to create"
  type        = number
  default     = 1
}