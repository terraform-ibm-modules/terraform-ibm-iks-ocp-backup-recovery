# Cloud automation for OpenShift workloads Backup Recovery (Fully configurable)

## Overview

This Deployable Architecture (DA) solution provides comprehensive backup and recovery capabilities for IBM Cloud Kubernetes Service (IKS) and Red Hat OpenShift on IBM Cloud (ROKS) clusters using IBM Backup Recovery Service (BRS).

### Key Features

- **Automated Backup**: Configure protection policies and protection groups for automated backups
- **Flexible Recovery Options**: Same-cluster and cross-cluster recovery capabilities
- **Auto-Protect**: Automatically protect all namespaces with a single policy
- **Granular Control**: Define specific protection groups for fine-grained backup control
- **Data Source Connector (DSC)**: Dedicated worker pool option for backup operations

## Documentation

For detailed information about recovery capabilities and implementation, see:

- [Recovery Implementation Guide](../../docs/RECOVERY_IMPLEMENTATION.md) - Comprehensive guide on recovery features, architecture, and best practices

## Usage Examples

See the [Recovery Implementation Guide](../../docs/RECOVERY_IMPLEMENTATION.md) for detailed usage examples including:

- Basic backup configuration
- Same-cluster recovery
- Cross-cluster recovery
- Multiple recovery operations

## Prerequisites

- IBM Cloud account with appropriate permissions
- Existing IKS or ROKS cluster (source)
- For cross-cluster recovery: Additional target cluster
- IBM Cloud API key with required permissions
- Terraform >= 1.3.0

## Required IAM Permissions

- **Backup Recovery Service**: Editor or Administrator
- **Kubernetes Service**: Editor or Administrator
- **VPC Infrastructure**: Editor (if creating DSC worker pools)
- **Resource Group**: Viewer

:exclamation: **Important:** This solution is not intended to be called by other modules because it contains a provider configuration and is not compatible with the `for_each`, `count`, and `depends_on` arguments. For more information, see [Providers Within Modules](https://developer.hashicorp.com/terraform/language/modules/develop/providers).
