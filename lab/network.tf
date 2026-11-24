resource "azurerm_virtual_network" "this" {
  name                = local.names.vnet
  resource_group_name = local.rg
  location            = local.location
  address_space       = [local.vnet_cidr]
  tags                = local.tags
}

# ---------- NSGs ----------

resource "azurerm_network_security_group" "aca" {
  name                = local.names.nsg_aca
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags

  # laravel-web has external ingress. VERIFY against the current Container Apps
  # networking docs: a consumption-only environment may need more rules.
  security_rule {
    name                       = "allow-web-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "pe" {
  name                = local.names.nsg_pe
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags

  security_rule {
    name                       = "allow-aca-to-pe"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = local.snet_aca_cidr
    destination_address_prefix = local.snet_pe_cidr
  }

  security_rule {
    name                       = "deny-other-in"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "mysql" {
  name                = local.names.nsg_mysql
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags

  security_rule {
    name                       = "allow-aca-to-mysql"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = local.snet_aca_cidr
    destination_address_prefix = local.snet_sql_cidr
  }
}

# ---------- Subnets ----------

resource "azurerm_subnet" "aca" {
  name                 = local.names.snet_aca
  resource_group_name  = local.rg
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.snet_aca_cidr]
}

resource "azurerm_subnet" "pe" {
  name                              = local.names.snet_pe
  resource_group_name               = local.rg
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [local.snet_pe_cidr]
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "mysql" {
  name                 = local.names.snet_mysql
  resource_group_name  = local.rg
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.snet_sql_cidr]

  delegation {
    name = "mysql-flexible"

    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "aca" {
  subnet_id                 = azurerm_subnet.aca.id
  network_security_group_id = azurerm_network_security_group.aca.id
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}

resource "azurerm_subnet_network_security_group_association" "mysql" {
  subnet_id                 = azurerm_subnet.mysql.id
  network_security_group_id = azurerm_network_security_group.mysql.id
}

# ---------- Private DNS zones, linked to the VNet ----------

locals {
  private_zones = {
    vault = "privatelink.vaultcore.azure.net"
    blob  = "privatelink.blob.core.windows.net"
    mysql = "privatelink.mysql.database.azure.com"
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = local.private_zones
  name                = each.value
  resource_group_name = local.rg
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each              = local.private_zones
  name                  = "link-${each.key}"
  resource_group_name   = local.rg
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = local.tags
}
