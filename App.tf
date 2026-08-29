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
  use_oidc        = true
}

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

data "azurerm_key_vault" "example" {
  name                 = "kv1-runne1r-secret1s"
  resource_group_name  = "tfstate"
}

data "azurerm_key_vault_secret" "example" {
  name          = "github-app-private-key"
  key_vault_id  = data.azurerm_key_vault.example.id
}


resource "azurerm_resource_group" "rg" {
  name           ="Demo-RGRP123"
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
  resource_group_name = azurerm_resource_group.rg.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  private_dns_zone_name = azurerm_private_dns_zone.private_dns_zone.name
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
      set -euo pipefail
      
      # Configuration Variables (injected by Terraform templatefile())
      KV_NAME="kv-runner-secrets"
      SECRET_NAME="github-app-private-key"
      APP_ID="4762328"
      INSTALLATION_ID="157533345"
      GITHUB_ORG="Be4rCl4w"     # bare org slug, e.g. "my-org"
      GITHUB_REPO="AppService"  # bare repo name, e.g. "my-repo"
      
      RUNNER_VERSION="2.336.0"
      RUNNER_USER="ghrunner"
      
      # 1. Prerequisites, including Microsoft's apt repo (required for azure-cli)
      apt-get update
      apt-get install -y jq openssl curl ca-certificates lsb-release gnupg
      
      curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg
      AZ_REPO=$(lsb_release -cs)
      echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" > /etc/apt/sources.list.d/azure-cli.list
      apt-get update
      apt-get install -y azure-cli
      
      # 2. Login using the VM's system-assigned Managed Identity (no client-id needed)
      az login --identity
      
      # 3. Fetch GitHub App private key from Key Vault
      PEM_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name "$SECRET_NAME" --query value -o tsv)
      if [ -z "$PEM_KEY" ]; then
        echo "ERROR: empty private key from Key Vault — check managed identity permissions" >&2
        exit 1
      fi
      
      # 4. Generate JWT for GitHub App authentication
      HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
      NOW=$(date +%s)
      PAYLOAD=$(echo -n "{\"iat\":$((NOW - 60)),\"exp\":$((NOW + 600)),\"iss\":\"$APP_ID\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
      SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | openssl dgst -sha256 -sign <(echo "$PEM_KEY") | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
      JWT="$HEADER.$PAYLOAD.$SIGNATURE"
      
      # 5. Exchange JWT for an installation access token
      INSTALLATION_TOKEN=$(curl -sf -X POST \
        -H "Authorization: Bearer $JWT" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/app/installations/"$INSTALLATION_ID"/access_tokens | jq -r .token)
      
      if [ -z "$INSTALLATION_TOKEN" ] || [ "$INSTALLATION_TOKEN" = "null" ]; then
        echo "ERROR: failed to obtain installation token" >&2
        exit 1
      fi
      
      # 6. Get a fresh REPO-level runner registration token (note: /repos, not /orgs)
      RUNNER_TOKEN=$(curl -sf -X POST \
        -H "Authorization: Bearer $INSTALLATION_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/orgs/"$GITHUB_ORG"/actions/runners/registration-token | jq -r .token)
      
      if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
        echo "ERROR: failed to obtain runner registration token — check GitHub App repo permissions" >&2
        exit 1
      fi
      
      # 7. Create a dedicated, unprivileged user to own and run the runner
      id -u "$RUNNER_USER" &>/dev/null || useradd -m -s /bin/bash "$RUNNER_USER"
      
      mkdir -p /actions-runner
      chown "$RUNNER_USER":"$RUNNER_USER" /actions-runner
      cd /actions-runner
      
      curl -o actions-runner-linux-x64.tar.gz -L \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
      tar xzf actions-runner-linux-x64.tar.gz
      chown -R "$RUNNER_USER":"$RUNNER_USER" /actions-runner
      
      # 8. Configure as the unprivileged user, against the repo-level URL
      sudo -u "$RUNNER_USER" ./config.sh \
        --url "https://github.com/$GITHUB_ORG/$GITHUB_REPO" \
        --token "$RUNNER_TOKEN" \
        --name "$(hostname)" \
        --unattended \
        --replace
      
      # 9. Install and start the service (this step does need root)
      ./svc.sh install "$RUNNER_USER"
      ./svc.sh start
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

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "demo_linux_os_disk"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"

  } 
  custom_data = data.cloudinit_config.runner_setup.rendered
}

resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = data.azurerm_key_vault.kv-runner-secrets.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.linux_vm.identity[0].principal_id
}

