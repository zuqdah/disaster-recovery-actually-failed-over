resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false

  # Keyed on both regions. A SQL server name reservation survives a failed
  # create and is bound to the region it was attempted in, so recreating the
  # same name elsewhere fails with InvalidResourceLocation even though nothing
  # is visibly using it. Changing region therefore has to change the name.
  keepers = {
    primary   = var.primary_location
    secondary = var.secondary_location
  }
}

locals {
  suffix           = random_string.suffix.result
  primary_server   = "${var.prefix}-sql-primary-${local.suffix}"
  secondary_server = "${var.prefix}-sql-secondary-${local.suffix}"
}

# One resource group per region. A resource group is not a failure domain, but
# keeping the regions apart makes it obvious at a glance which resources are
# supposed to survive the loss of the other.
resource "azurerm_resource_group" "primary" {
  name     = "rg-${var.prefix}-${var.primary_location}"
  location = var.primary_location
}

resource "azurerm_resource_group" "secondary" {
  name     = "rg-${var.prefix}-${var.secondary_location}"
  location = var.secondary_location
}

# Entra-only authentication on both servers. A SQL login and password would be
# one more thing to replicate, and a credential that works on the primary but
# was never created on the secondary is a failover that succeeds and then
# refuses every connection.
resource "azurerm_mssql_server" "primary" {
  name                          = local.primary_server
  resource_group_name           = azurerm_resource_group.primary.name
  location                      = azurerm_resource_group.primary.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  azuread_administrator {
    login_username              = var.entra_admin_login
    object_id                   = var.entra_admin_object_id
    azuread_authentication_only = true
  }
}

resource "azurerm_mssql_server" "secondary" {
  name                          = local.secondary_server
  resource_group_name           = azurerm_resource_group.secondary.name
  location                      = azurerm_resource_group.secondary.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  azuread_administrator {
    login_username              = var.entra_admin_login
    object_id                   = var.entra_admin_object_id
    azuread_authentication_only = true
  }
}

resource "azurerm_mssql_database" "orders" {
  name      = "orders"
  server_id = azurerm_mssql_server.primary.id
  sku_name  = var.sku_name
  collation = "SQL_Latin1_General_CP1_CI_AS"

  # The drill destroys and recreates this repeatedly; a long-term backup policy
  # would outlive the database it protects and bill for it.
  storage_account_type = "Local"
}

# The listener is the whole point. Applications connect to the failover group
# endpoint, not to a server, so a failover moves the endpoint rather than
# requiring every client to be reconfigured. A drill that reconnects by editing
# a connection string has proved the replica works and proved nothing about the
# recovery.
resource "azurerm_mssql_failover_group" "orders" {
  name      = "${var.prefix}-fog-${local.suffix}"
  server_id = azurerm_mssql_server.primary.id
  databases = [azurerm_mssql_database.orders.id]

  partner_server {
    id = azurerm_mssql_server.secondary.id
  }

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60
  }
}

# Both servers get the same rules, and only these. A secondary that is
# unreachable from where the application runs is not a standby, and configuring
# the two asymmetrically means discovering that during the failover.
#
# There is deliberately no "allow Azure services" rule. The 0.0.0.0 entry that
# enables it is not scoped to this subscription or even this tenant -- it admits
# any Azure resource anywhere -- and the drill runs on a GitHub-hosted runner,
# which is not in Azure and is already covered by the rule below. It would have
# been a permanent hole opened for a convenience nothing here needs.
resource "azurerm_mssql_firewall_rule" "client_primary" {
  count            = var.client_ip == "" ? 0 : 1
  name             = "allow-drill-client"
  server_id        = azurerm_mssql_server.primary.id
  start_ip_address = var.client_ip
  end_ip_address   = var.client_ip
}

resource "azurerm_mssql_firewall_rule" "client_secondary" {
  count            = var.client_ip == "" ? 0 : 1
  name             = "allow-drill-client"
  server_id        = azurerm_mssql_server.secondary.id
  start_ip_address = var.client_ip
  end_ip_address   = var.client_ip
}
