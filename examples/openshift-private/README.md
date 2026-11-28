# OpenShift private-network example

<!-- BEGIN SCHEMATICS DEPLOY HOOK -->
<p>
  <a href="https://cloud.ibm.com/schematics/workspaces/create?workspace_name=iks-ocp-backup-recovery-openshift-private-example&repository=https://github.com/terraform-ibm-modules/terraform-ibm-iks-ocp-backup-recovery/tree/main/examples/openshift-private">
    <img src="https://img.shields.io/badge/Deploy%20with%20IBM%20Cloud%20Schematics-0f62fe?style=flat&logo=ibm&logoColor=white&labelColor=0f62fe" alt="Deploy with IBM Cloud Schematics">
  </a><br>
  ℹ️ Ctrl/Cmd+Click or right-click on the Schematics deploy button to open in a new tab.
</p>
<!-- END SCHEMATICS DEPLOY HOOK -->


A variant of the [OpenShift example](../openshift) that mimics a locked-down customer environment: a private-only VPC with
**no public gateway**, and a cluster with **no public service endpoint**.

This example provisions the following:

- A new resource group, if an existing one is not passed in.
- A VPC and a single subnet **without** a public gateway (workers have no route to the public internet).
- A single zone OCP VPC cluster with `disable_public_endpoint = true` and (by default) outbound traffic protection left on.
- A Cloud Object Storage instance (for the cluster's internal registry).
- A new Backup & Recovery instance, or an existing one when `existing_brs_instance_crn` is set.
- A Virtual Private Endpoint gateway so that the Data Source Connector reaches BRS over the IBM private backbone. It is
  created **before** the connector is installed, because there is no other path to BRS.
- The Data Source Connector, source registration, a test workload (`<prefix>-demo-ns` with a 20 Gi block volume) and a
  protection group for that namespace.

## Prerequisites

The cluster has no public endpoint, so the machine running `terraform apply` must be able to reach the cluster **private**
service endpoint (VPN, Direct Link, or a host inside the VPC). Without that, reading the cluster config and the Helm and
Kubernetes providers will time out. The BRS API is reached over its public endpoint by default (`brs_endpoint_type = "public"`).

Use a `prefix` that is different from the one used by [`examples/openshift`](../openshift) if that example is deployed in
the same account and region, because VPC and cluster names must be unique.

## Usage

```hcl
# terraform.tfvars (do not commit; it is gitignored)
prefix         = "bnpp-priv"
region         = "us-east"
resource_group = "<existing resource group>"

# Optional: reuse an existing BRS instance
# existing_brs_instance_crn = "crn:v1:bluemix:public:backup-recovery:..."
```

Provide the API key through the environment instead of a file:

```sh
export TF_VAR_ibmcloud_api_key="$IBMCLOUD_API_KEY"
```

```sh
terraform init
terraform apply
```

## Notes

- Set `disable_outbound_traffic_protection = true` if you need workers to reach the public internet (for example, to
  compare behaviour with and without outbound protection).
- This example is VPC only. It does not support Classic clusters or an existing cluster.
