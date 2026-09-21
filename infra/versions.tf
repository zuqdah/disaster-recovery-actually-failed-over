terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "azurerm" {
  # The nine other labs in this series registered providers per subscription
  # already, and a lab should not be quietly changing subscription-wide state.
  resource_provider_registrations = "none"

  features {}
}
