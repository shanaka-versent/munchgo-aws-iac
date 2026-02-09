# EKS Module Variables
# @author Shanaka Jayasundera - shanakaj@gmail.com

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "subnet_ids" {
  description = "Subnet IDs for EKS cluster"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnet IDs for node groups"
  type        = list(string)
}

# System Node Pool
variable "system_node_count" {
  description = "Number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_instance_type" {
  description = "Instance type for system nodes"
  type        = string
  default     = "t3.medium"
}

variable "system_node_min_count" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 3
}

# User Node Pool
variable "enable_user_node_pool" {
  description = "Enable user node pool"
  type        = bool
  default     = true
}

variable "user_node_count" {
  description = "Number of user nodes"
  type        = number
  default     = 2
}

variable "user_node_instance_type" {
  description = "Instance type for user nodes"
  type        = string
  default     = "t3.medium"
}

variable "user_node_min_count" {
  description = "Minimum number of user nodes"
  type        = number
  default     = 1
}

variable "user_node_max_count" {
  description = "Maximum number of user nodes"
  type        = number
  default     = 5
}

# Autoscaling
variable "enable_autoscaling" {
  description = "Enable autoscaling for node groups"
  type        = bool
  default     = false
}

# Logging
variable "enable_logging" {
  description = "Enable EKS control plane logging"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for resources"
  type        = map(string)
  default     = {}
}
