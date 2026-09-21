variable "primary_location" {
  description = "Where the primary replica lives."
  type        = string
  default     = "westus2"
}

variable "secondary_location" {
  description = <<-EOT
    Where the standby replica lives. westus2 and westcentralus are an official
    Azure region pair and both report Available for Microsoft.Sql on this
    subscription. Check before changing: the capabilities API reports a region
    as Visible when it is listed but refuses to provision into it, which fails
    at apply time with ProvisioningDisabled rather than at plan time.
  EOT
  type        = string
  default     = "westcentralus"
}

variable "prefix" {
  description = "Name prefix, so a stray resource is obviously from this lab."
  type        = string
  default     = "drdrill"
}

variable "sku_name" {
  description = <<-EOT
    S0 rather than serverless, and the reason is cost rather than capability.
    A geo-replicated secondary cannot auto-pause, so serverless bills both
    replicas continuously at roughly $0.52 per vCore-hour for the pair, while
    two S0 databases cost about $0.04 an hour for identical failover mechanics.
    At real volumes the tier choice would be driven by the workload instead.
  EOT
  type        = string
  default     = "S0"
}

variable "entra_admin_object_id" {
  description = "Object ID of the Entra principal that administers both servers."
  type        = string
}

variable "entra_admin_login" {
  description = "Display name of that principal."
  type        = string
}

variable "client_ip" {
  description = "Public IP allowed through the SQL firewall, set to the runner's address at deploy time."
  type        = string
  default     = ""
}
