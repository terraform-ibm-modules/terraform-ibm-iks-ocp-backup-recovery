# Configuring complex inputs for OpenShift Backup and Recovery in IBM Cloud projects

Several optional input variables in the OpenShift Backup and Recovery [Deployable Architecture](https://cloud.ibm.com/catalog#deployable_architecture) use complex object types. You can specify these inputs when you configure your deployable architecture.

- [Add-ons](#options-with-addons) (`addons`)
- [Infra node selectors](#options-with-infra) (`infra_node_selectors`)
- [Workloads node selectors](#options-with-workload) (`workloads_node_selectors`)

## Options with `addons` <a name="options-with-addons"></a>

This variable configuration allows you to specify which Red Hat OpenShift add-ons to install on your cluster and the version of each add-on to use.

- Variable name: `addons`
- Type: An object representing Red Hat OpenShift cluster add-ons.
- Default value: An empty object (`{}`).

### Supported Add-ons

- `debug-tool` (optional): (Object) The Debug Tool add-on helps diagnose and troubleshoot cluster issues by running tests and gathering information, accessible through the Red Hat OpenShift console.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `image-key-synchronizer` (optional): (Object) The Image Key Synchronizer add-on enables the deployment of containers using encrypted images by synchronizing image keys, ensuring only authorized users can access and run them.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `openshift-data-foundation` (optional): (Object) The Red Hat OpenShift Data Foundation (ODF) add-on manages persistent storage for containerized applications with a highly available storage solution.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `vpc-file-csi-driver` (optional): (Object) The Virtual Private Cloud File Container Storage Interface Driver add-on enables the creation of persistent volume claims for fast, flexible, network-attached, Network File System-based file storage for Virtual Private Cloud.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `static-route` (optional): (Object) The Static Route add-on allows worker nodes to re-route response packets through a virtual private network or gateway to an Internet Protocol (IP) address in an on-premises data center.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `cluster-autoscaler` (optional): (Object) The Cluster Autoscaler add-on automatically scales worker pools based on the resource demands of scheduled workloads.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `vpc-block-csi-driver` (optional): (Object) The Virtual Private Cloud (VPC) Block Container Storage Interface (CSI) Driver add-on enables snapshotting of storage volumes, allowing users to restore data from specific points in time without duplicating the volume.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `ibm-storage-operator` (optional): (Object) The IBM Storage Operator add-on streamlines the management of storage configuration maps and resources in your cluster.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

- `openshift-ai` (optional): (Object) The Red Hat OpenShift AI add-on enables quick deployment of Red Hat OpenShift AI on a Red Hat OpenShift Cluster in IBM Cloud.
  - `version` (optional): The add-on version. Omit the version that you want to use as the default version.This is required when you want to update the add-on to specified version.
  - `parameters_json` (optional): Add-On parameters to pass in a JSON string format.

Please refer to [this](https://cloud.ibm.com/docs/containers?topic=containers-supported-cluster-addon-versions) page for information on supported add-ons and their versions.

### Example for addons configuration

```hcl
{
  openshift-data-foundation = {
    version         = "4.17.0"
    parameters_json = <<PARAMETERS_JSON
        {
            "osdStorageClassName":"localblock",
            "odfDeploy":"true",
            "autoDiscoverDevices":"true"
        }
        PARAMETERS_JSON
  }
  vpc-file-csi-driver = {
    version = "2.0"
  }
}
```
