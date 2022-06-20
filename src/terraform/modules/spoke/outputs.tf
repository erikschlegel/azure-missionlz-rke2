# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

output "virtual_network_id" {
  description = "The id of the virtual network"
  value       = module.spoke-network.virtual_network_id
}

output "virtual_network_subnet_ids" {
  description = "The list of subnet ids of the virtual network"
  value = [
    for subnet in module.subnets : subnet.subnet_id
  ]
}
