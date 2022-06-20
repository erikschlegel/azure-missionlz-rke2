# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

output "subnet_id" {
  description = "The id of the subnet"
  value       = azurerm_subnet.subnet.id
}
