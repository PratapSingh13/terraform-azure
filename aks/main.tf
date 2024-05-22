resource "azurerm_resource_group" "aks_rg" {
  name     = "azure_learning"
  location = var.resource_group_location
}

# Provision AKS Cluster
/*
1. Add Basic Cluster Settings
  - Get Latest Kubernetes Version from datasource (kubernetes_version)
  - Add Node Resource Group (node_resource_group)
2. Add Default Node Pool Settings
  - orchestrator_version (latest kubernetes version using datasource)
  - availability_zones
  - enable_auto_scaling
  - max_count, min_count
  - os_disk_size_gb
  - type
  - node_labels
  - tags
3. Enable MSI
4. Add On Profiles 
  - Azure Policy
  - Azure Monitor (Reference Log Analytics Workspace id)
5. RBAC & Azure AD Integration
6. Admin Profiles
  - Windows Admin Profile
  - Linux Profile
7. Network Profile
8. Cluster Tags  
*/

# Create virtual network
resource "azurerm_virtual_network" "terraform_vnet" {
  name                = "terraform_az_vnet"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name

  tags = {
    environment = "learning"
  }

  depends_on = [
    azurerm_resource_group.aks_rg
  ]
}

# Create subnet
resource "azurerm_subnet" "terraform_subnet_1" {
  name                 = "terraform_az_subnet_1"
  resource_group_name  = azurerm_resource_group.aks_rg.name
  virtual_network_name = azurerm_virtual_network.terraform_vnet.name
  address_prefixes     = ["10.0.0.0/20"]

  depends_on = [azurerm_resource_group.aks_rg,
    azurerm_virtual_network.terraform_vnet
  ]
}

# Datasource to get Latest Azure AKS latest Version
data "azurerm_kubernetes_service_versions" "current" {
  location        = azurerm_resource_group.aks_rg.location
  include_preview = false
}

resource "azurerm_kubernetes_cluster" "terraform_aks" {
  name                              = var.cluster_name == null ? "${var.prefix}-aks" : var.cluster_name
  location                          = azurerm_resource_group.aks_rg.location
  resource_group_name               = azurerm_resource_group.aks_rg.name
  kubernetes_version                = var.kubernetes_version == null ? data.azurerm_kubernetes_service_versions.current.latest_version : var.kubernetes_version
  dns_prefix                        = var.prefix
  node_resource_group               = "${azurerm_resource_group.aks_rg.name}-nrg"
  sku_tier                          = var.sku_tier
  private_cluster_enabled           = var.private_cluster_enabled
  http_application_routing_enabled  = var.enable_http_application_routing
  azure_policy_enabled              = var.enable_azure_policy
  role_based_access_control_enabled = var.enable_role_based_access_control

  linux_profile {
    admin_username = var.admin_username
    ssh_key {
      key_data = var.key_data == "azureKey" ? file(var.ssh_public_key) : var.key_data
    }
  }
  dynamic "default_node_pool" {
    for_each = var.agents_pool_name == "nodepool" ? ["default_node_pool"] : []
    content {
      name                 = var.agents_pool_name
      orchestrator_version = var.orchestrator_version
      node_count           = var.node_count
      vm_size              = var.vm_size
      os_disk_size_gb      = var.os_disk_size_gb
      enable_auto_scaling  = var.enable_auto_scaling
      max_count            = var.max_count
      min_count            = var.min_count
    #   vnet_subnet_id        = azurerm_subnet.terraform_subnet_1.id
      type                  = var.agents_type
    #   availability_zones     = var.agents_availability_zones
      node_labels            = var.agents_labels
      max_pods               = var.agents_max_pods
      enable_host_encryption = var.enable_host_encryption
      tags                   = merge(var.tags, var.agents_tags)
    }
  }
  depends_on = [
    azurerm_subnet.terraform_subnet_1
  ]

  dynamic "service_principal" {
    for_each = var.client_id != "" && var.client_secret != "" ? ["service_principal"] : []
    content {
      client_id     = var.client_id
      client_secret = var.client_secret
    }
  }

  dynamic "identity" {
    for_each = var.client_id == "" || var.client_secret == "" ? ["identity"] : []
    content {
      type = var.identity_type
    #   user_assigned_identity_id = var.identity_type == "UserAssigned" ? azurerm_user_assigned_identity.aks_identity[0].id : null
    }
  }

  dynamic "oms_agent" {
    for_each = var.oms_agent_log_analytics_workspace_id != null ? [true] : []
    content {
      log_analytics_workspace_id = var.oms_agent_log_analytics_workspace_id
    }
  }

  dynamic "ingress_application_gateway" {
    for_each = var.enable_ingress_application_gateway == null ? [] : ["ingress_application_gateway"]
    content {
      gateway_id   = var.ingress_application_gateway_id
      gateway_name = var.ingress_application_gateway_name
      subnet_cidr  = var.ingress_application_gateway_subnet_cidr
      #   subnet_cidr = ["10.0.1.0/24"]
    #   subnet_id = var.ingress_application_gateway_subnet_id
      subnet_id = azurerm_subnet.terraform_subnet_1.id
    }
  }

  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.enable_role_based_access_control && var.rbac_ad_managed ? [1] : []
    content {
      managed                = var.rbac_ad_managed
      admin_group_object_ids = var.rbac_ad_admin_group_object_ids
      azure_rbac_enabled     = var.enable_role_based_access_control
    }
  }

  network_profile {
    network_plugin     = var.network_plugin == var.network_policy ? var.network_plugin : "kubenet"
    # network_plugin = "azure"
    network_policy     = var.network_policy == null ? var.network_policy : "calico"
    dns_service_ip     = var.net_profile_dns_service_ip == null ? var.net_profile_dns_service_ip : "10.0.0.10"
    docker_bridge_cidr = var.net_profile_docker_bridge_cidr == null ? var.net_profile_docker_bridge_cidr : "170.10.0.1/16"
    outbound_type      = var.net_profile_outbound_type
    pod_cidr           = var.network_plugin == "kubenet" ? var.net_profile_pod_cidr : null
    service_cidr       = var.net_profile_service_cidr == null ? var.net_profile_service_cidr : "10.0.0.0/16"
    load_balancer_sku  = "standard"
  }

  tags = var.tags
}

resource "azurerm_log_analytics_workspace" "log" {
  count               = var.enable_log_analytics_workspace ? 1 : 0
  name                = var.cluster_log_analytics_workspace_name == null ? "${var.prefix}-workspace" : var.cluster_log_analytics_workspace_name
  location            = azurerm_resource_group.aks_rg.location
  resource_group_name = azurerm_resource_group.aks_rg.name
  sku                 = var.log_analytics_workspace_sku
  retention_in_days   = var.log_retention_in_days

  tags = var.tags

  depends_on = [
    azurerm_kubernetes_cluster.terraform_aks
  ]
}