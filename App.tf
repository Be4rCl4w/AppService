terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "4.81.0"
    }

    azuread = {
      source = "hashicorp/azuread"
      version = "3.5.0"
    }
  }
}

provider "azuread" {}
provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "primary" {}

terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate1unique123"
    container_name        = "tfstate"
    key                   = "prod.terraform.tfstate"
    use_azuread_auth      = true
  }
}

variable "ssh_public_key" {
  type = string
}


resource "azurerm_resource_group" "rg" {
  name           ="Demo-RG"
  location       = "North Europe"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "Demo-VNet"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

locals {
  subnets = {
    "Demo-subnet" = {
      address_prefix = "10.20.0.0/24"
      delegate       = false  # No delegation
    }
    "runner-subnet" = {
      address_prefix = "10.20.1.0/27"
      delegate       = false # No delegation
    }
    "Delegated-subnet" = {
      address_prefix = "10.20.2.0/24"
      delegate       = true  # Enable delegation for App Service
    }
  }
}

resource "azurerm_subnet" "subnet" {
  for_each             = local.subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [each.value.address_prefix]

  # Conditionally add delegation block using dynamic
  dynamic "delegation" {
    for_each = each.value.delegate ? [1] : []

    content {
      name = "app-service-delegation"

      service_delegation {
        name    = "Microsoft.Web/serverFarms"
        actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
      }
    }
  }
}

resource "azurerm_public_ip" "vm_public_ip" {
  name                = "runner_vm_public_ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
}


resource "azurerm_network_interface" "linux_nic" {
  name                = "demo_linux_nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "demo_linux_ip_config"
    subnet_id                     = azurerm_subnet.subnet["runner-subnet"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = azurerm_public_ip.vm_public_ip.id
  }
}


resource "azurerm_private_dns_zone" "private_dns_zone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "app_service" {
  name                  = "link1"
  private_dns_zone_id   = azurerm_private_dns_zone.private_dns_zone.id
  virtual_network_id    = azurerm_virtual_network.vnet.id
}
  
resource "azurerm_private_endpoint" "app" {
  name                = "pe-1"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.subnet["Demo-subnet"].id

  private_service_connection {
    name                           = "psc"
    private_connection_resource_id = azurerm_linux_web_app.example.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-1"
    private_dns_zone_ids = [azurerm_private_dns_zone.private_dns_zone.id]
  }
}


resource "azurerm_network_security_group" "NSG" {
  name = "runner-NSG"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = 443
    source_address_prefix      = azurerm_linux_virtual_machine.linux_vm.private_ip_address
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSSH"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = 22
    source_address_prefix      = "*"
    destination_address_prefix = azurerm_linux_virtual_machine.linux_vm.private_ip_address
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.subnet["runner-subnet"].id
  network_security_group_id = azurerm_network_security_group.NSG.id
}

resource "azurerm_service_plan" "example" {
  name                = "Myexample"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "P0v3"
}

resource "azurerm_linux_web_app" "example" {
  name                = "miWebapp65748"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.example.id

  site_config {
    always_on                        = true
    minimum_tls_version               = "1.2"
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 5
    vnet_route_all_enabled            = true

    application_stack {
      node_version = "24-lts"
    }
  } 

  https_only = true
  public_network_access_enabled = false
  virtual_network_subnet_id = azurerm_subnet.subnet["Delegated-subnet"].id
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }
  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT"               = "true"
    "ApplicationInsightsAgent_EXTENSION_VERSION" = "~3"
    "APPLICATIONINSIGHTS_CONNECTION_STRING"        = azurerm_application_insights.appi.connection_string
  }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 30
        retention_in_mb   = 100
      }
    }
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "logAnatSpace"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = "30"
}

resource "azurerm_application_insights" "appi" {
  name                = "app-insight"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}

data "cloudinit_config" "runner_setup" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = <<-EOF
      #!/bin/bash
      # 1. Create runner directory
      mkdir -p /actions-runner && cd /actions-runner

      # 2. Download latest runner package
      curl -o actions-runner-linux-x64-2.336.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz

      #Extract installer
      tar xzf ./actions-runner-linux-x64-2.336.0.tar.gz


      # 3. Configure and register runner non-interactively
     ./config.sh --url https://github.com/Be4rCl4w/AppService \
                  --token A5CWCEWXTAN6XAUKG4TTSY3KSDKL2 \
                  --unattended \
                  --replace

      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
      
      # 4. Install & start background service
      sudo ./svc.sh install
      sudo ./svc.sh start
    EOF
  }
}

resource "azurerm_linux_virtual_machine" "linux_vm" {
  name                  = "demo_linux_vm"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.linux_nic.id]
  size                  = "Standard_B1s" #Standard_B1s  Standard_D2ds_v4
  computer_name         = "linuxvm"

  admin_username = "adminuser1"
  
  admin_ssh_key {
    public_key     = var.ssh_public_key
    username       = "adminuser1"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  os_disk {
    name                 = "demo_linux_os_disk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"

  } 
  custom_data = data.cloudinit_config.runner_setup.rendered
}

