output "listener_fqdn" {
  description = "The failover group endpoint. Everything in the drill connects here and never to a server directly."
  value       = "${azurerm_mssql_failover_group.orders.name}.database.windows.net"
}

output "failover_group_name" {
  value = azurerm_mssql_failover_group.orders.name
}

output "primary_server_name" {
  value = azurerm_mssql_server.primary.name
}

output "secondary_server_name" {
  value = azurerm_mssql_server.secondary.name
}

output "primary_resource_group" {
  value = azurerm_resource_group.primary.name
}

output "secondary_resource_group" {
  value = azurerm_resource_group.secondary.name
}

output "database_name" {
  value = azurerm_mssql_database.orders.name
}
