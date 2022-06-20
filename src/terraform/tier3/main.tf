# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
terraform {
  # It is recommended to use remote state instead of local
  # If you are using Terraform Cloud, You can update these values in order to configure your remote state.
  /*  backend "remote" {
    organization = "{{ORGANIZATION_NAME}}"
    workspaces {
      name = "{{WORKSPACE_NAME}}"
    }
  }
  */
  backend "azurerm" {
    key = "terraform.tfstate.tier3"
  }

  required_version = ">= 1.0.11"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>2.67.0"
    }
  }
}

data "terraform_remote_state" "hub" {
  backend = "azurerm"
  config = {
    key                  = "terraform.tfstate.hub"
    container_name       = "statestore"
    storage_account_name = "amlztfstate"
  }
}

locals {
  hub_subid           = data.terraform_remote_state.hub.outputs.hub_subid
  hub_rgname          = data.terraform_remote_state.hub.outputs.hub_rgname
  hub_vnetname        = data.terraform_remote_state.hub.outputs.hub_vnetname
  firewall_private_ip = data.terraform_remote_state.hub.outputs.firewall_private_ip
  tier1_subid         = data.terraform_remote_state.hub.outputs.tier1_subid
  laws_name           = data.terraform_remote_state.hub.outputs.laws_name
  laws_rgname         = data.terraform_remote_state.hub.outputs.laws_rgname
}

provider "azurerm" {
  environment     = var.environment
  metadata_host   = var.metadata_host
  subscription_id = local.hub_subid

  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azurerm" {
  alias           = "hub"
  environment     = var.environment
  metadata_host   = var.metadata_host
  subscription_id = local.hub_subid

  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azurerm" {
  alias           = "tier1"
  environment     = var.environment
  metadata_host   = var.metadata_host
  subscription_id = local.tier1_subid

  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

provider "azurerm" {
  alias           = "tier3"
  environment     = var.environment
  metadata_host   = var.metadata_host
  subscription_id = var.tier3_subid

  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

################################
### STAGE 0: Scaffolding     ###
################################

resource "azurerm_resource_group" "tier3" {
  provider = azurerm.tier3

  location = var.location
  name     = var.tier3_rgname
  tags     = var.tags
}

################################
### STAGE 1: Logging         ###
################################

data "azurerm_log_analytics_workspace" "laws" {
  provider = azurerm.tier1

  name                = local.laws_name
  resource_group_name = local.laws_rgname
}

// Central Logging
locals {
  log_categories = ["Administrative", "Security", "ServiceHealth", "Alert", "Recommendation", "Policy", "Autoscale", "ResourceHealth"]
}

resource "azurerm_monitor_diagnostic_setting" "tier3-central" {
  count              = var.tier3_subid != local.hub_subid ? 1 : 0
  provider           = azurerm.tier3
  name               = "tier3-central-diagnostics"
  target_resource_id = "/subscriptions/${var.tier3_subid}"

  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.laws.id

  dynamic "log" {
    for_each = local.log_categories
    content {
      category = log.value
      enabled  = true

      retention_policy {
        days    = 0
        enabled = false
      }
    }
  }
}

################################
### STAGE 2: Networking      ###
################################

data "azurerm_virtual_network" "hub" {
  name                = local.hub_vnetname
  resource_group_name = local.hub_rgname
}

module "spoke-network-t3" {
  providers  = { azurerm = azurerm.tier3 }
  depends_on = [azurerm_resource_group.tier3]
  source     = "../modules/spoke"

  location = azurerm_resource_group.tier3.location

  firewall_private_ip = local.firewall_private_ip

  laws_location     = var.location
  laws_workspace_id = data.azurerm_log_analytics_workspace.laws.workspace_id
  laws_resource_id  = data.azurerm_log_analytics_workspace.laws.id

  spoke_rgname             = var.tier3_rgname
  spoke_vnetname           = var.tier3_vnetname
  spoke_vnet_address_space = var.tier3_vnet_address_space
  subnets                  = var.tier3_subnets
  tags                     = var.tags
}

resource "azurerm_virtual_network_peering" "t3-to-hub" {
  provider   = azurerm.tier3
  depends_on = [azurerm_resource_group.tier3, module.spoke-network-t3]

  name                         = "${var.tier3_vnetname}-to-${local.hub_vnetname}"
  resource_group_name          = var.tier3_rgname
  virtual_network_name         = var.tier3_vnetname
  remote_virtual_network_id    = data.azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub-to-t3" {
  provider   = azurerm.hub
  depends_on = [module.spoke-network-t3]

  name                         = "${local.hub_vnetname}-to-${var.tier3_vnetname}"
  resource_group_name          = local.hub_rgname
  virtual_network_name         = local.hub_vnetname
  remote_virtual_network_id    = module.spoke-network-t3.virtual_network_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

module "rke2" {
  source                 = "github.com/rancherfederal/rke2-azure-tf"
  cluster_name           = "rke2-cluster"
  subnet_id              = module.spoke-network-t3.virtual_network_subnet_ids[0]
  server_public_ip       = var.server_public_ip
  server_open_ssh_public = var.server_open_ssh_public
  vm_size                = var.vm_size
  server_instance_count  = var.server_instance_count
  agent_instance_count   = var.agent_instance_count
  cloud                  = var.environment == "public" ? "AzurePublicCloud" : "AzureUSGovernmentCloud"
}
