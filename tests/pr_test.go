// Tests in this file are run in the PR pipeline and the continuous testing pipeline
package test

import (
	"context"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/files"
	"github.com/gruntwork-io/terratest/modules/logger"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/terraform-ibm-modules/ibmcloud-terratest-wrapper/cloudinfo"
	"github.com/terraform-ibm-modules/ibmcloud-terratest-wrapper/common"
	"github.com/terraform-ibm-modules/ibmcloud-terratest-wrapper/testhelper"
	"github.com/terraform-ibm-modules/ibmcloud-terratest-wrapper/testschematic"
)

// Use existing resource group
// const resourceGroup = "geretain-test-resources"
const resourceGroup = "BRT-General-testing"
const existing_brs_instance_crn = "crn:v1:bluemix:public:backup-recovery:au-syd:a/7d8f9e928b9d6c2dfa06475946765e01:4dde55c7-e8a8-48c8-b431-c226f75090f7::"
const fullyConfigurableTerraformDir = "solutions/fully-configurable"
const iksExampleDir = "examples/kubernetes"
const ocpExampleDir = "examples/openshift"
const crossClusterExampleDir = "examples/backup-recovery-cross-cluster"

var excludeDirs = []string{".terraform", ".docs", ".github", ".git", ".idea", "common-dev-assets", "examples", "tests", "reference-architectures"}

var includeFiletypes = []string{".tf", ".yaml", ".py", ".tpl", ".md", ".sh"}

const yamlLocation = "../common-dev-assets/common-go-assets/common-permanent-resources.yaml"

// Current supported regions
var validRegions = []string{
	"us-south",
	"us-east",
	"eu-es",
}

var (
	sharedInfoSvc      *cloudinfo.CloudInfoService
	permanentResources map[string]interface{}
)

type tarIncludePatterns struct {
	excludeDirs []string

	includeFiletypes []string

	includeDirs []string
}

func getTarIncludePatternsRecursively(dir string, dirsToExclude []string, fileTypesToInclude []string) ([]string, error) {
	r := tarIncludePatterns{dirsToExclude, fileTypesToInclude, nil}
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		return walk(&r, path, entry, err)
	})
	if err != nil {
		fmt.Println("error")
		return r.includeDirs, err
	}
	return r.includeDirs, nil
}

func walk(r *tarIncludePatterns, s string, d fs.DirEntry, err error) error {
	if err != nil {
		return err
	}
	if d.IsDir() {
		for _, excludeDir := range r.excludeDirs {
			if strings.Contains(s, excludeDir) {
				return nil
			}
		}
		if s == ".." {
			r.includeDirs = append(r.includeDirs, "*.tf")
			return nil
		}
		for _, includeFiletype := range r.includeFiletypes {
			r.includeDirs = append(r.includeDirs, strings.ReplaceAll(s+"/*"+includeFiletype, "../", ""))
		}
	}
	return nil
}

// TestMain will be run before any parallel tests, used to set up a shared InfoService object to track region usage
// for multiple tests
func TestMain(m *testing.M) {
	sharedInfoSvc, _ = cloudinfo.NewCloudInfoServiceFromEnv("TF_VAR_ibmcloud_api_key", cloudinfo.CloudInfoServiceOptions{})

	var err error
	permanentResources, err = common.LoadMapFromYaml(yamlLocation)
	if err != nil {
		log.Fatal(err)
	}

	os.Exit(m.Run())
}

func setupTerraform(t *testing.T, prefix, realTerraformDir string) *terraform.Options {
	tempTerraformDir, err := files.CopyTerraformFolderToTemp(realTerraformDir, prefix)
	require.NoError(t, err, "Failed to create temporary Terraform folder")

	region := validRegions[common.CryptoIntn(len(validRegions))]

	existingTerraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: tempTerraformDir,
		Vars: map[string]interface{}{
			"prefix":         prefix,
			"region":         region,
			"resource_group": resourceGroup,
			// "existing_brs_instance_crn": permanentResources["brs_us_east_crn"],
			"existing_brs_instance_crn": existing_brs_instance_crn,
		},
		// Set Upgrade to true to ensure latest version of providers and modules are used by terratest.
		// This is the same as setting the -upgrade=true flag with terraform.
		Upgrade: true,
	})

	terraform.InitContext(t, context.Background(), existingTerraformOptions)
	terraform.WorkspaceSelectOrNewContext(t, context.Background(), existingTerraformOptions, prefix)
	_, err = terraform.InitAndApplyContextE(t, context.Background(), existingTerraformOptions)
	require.NoError(t, err, "Init and Apply of temp existing resource failed")

	return existingTerraformOptions
}

func cleanupTerraform(t *testing.T, options *terraform.Options, prefix string) {
	if t.Failed() && strings.ToLower(os.Getenv("DO_NOT_DESTROY_ON_FAILURE")) == "true" {
		fmt.Println("Terratest failed. Debug the test and delete resources manually.")
		return
	}
	logger.Log(t, "START: Destroy (existing resources)")
	// Drop the BRS data-source connection from local state before destroy.
	// The Schematics workspace may have already deleted the connection, causing
	// the IBM provider's Delete to return HTTP 400 "does not exist" (provider
	// bug: should treat this as already-gone). Removing it from state avoids
	// the fatal error until https://github.com/IBM-Cloud/terraform-provider-ibm/pull/6906
	// is merged and released.
	// Exit code 1 is expected when the resource is not in state (e.g. count=0,
	// already removed, or this stateDir belongs to resources-cross-cluster which
	// only has source_connection/target_connection but not backup_recovery_instance).
	// Assign to _ to make the discard explicit and satisfy the linter.
	_, _ = terraform.RunTerraformCommandContextE(t, context.Background(), options, "state", "rm", "module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
	_, _ = terraform.RunTerraformCommandContextE(t, context.Background(), options, "state", "rm", "module.source_connection.ibm_backup_recovery_data_source_connection.connection[0]")
	_, _ = terraform.RunTerraformCommandContextE(t, context.Background(), options, "state", "rm", "module.target_connection.ibm_backup_recovery_data_source_connection.connection[0]")
	// Skip refresh on destroy for the same reason.
	options.ExtraArgs.Destroy = append(options.ExtraArgs.Destroy, "-refresh=false")
	terraform.DestroyContext(t, context.Background(), options)
	terraform.WorkspaceDeleteContext(t, context.Background(), options, prefix)
	logger.Log(t, "END: Destroy (existing resources)")
}

func getSchematicTerraformVars(t *testing.T, prefix string, options *testschematic.TestSchematicOptions, existingTerraformOptions *terraform.Options) []testschematic.TestSchematicTerraformVar {
	return []testschematic.TestSchematicTerraformVar{
		{Name: "ibmcloud_api_key", Value: options.RequiredEnvironmentVars["TF_VAR_ibmcloud_api_key"], DataType: "string", Secure: true},
		{Name: "cluster_id", Value: terraform.OutputContext(t, context.Background(), existingTerraformOptions, "workload_cluster_id"), DataType: "string"},
		{Name: "cluster_resource_group_id", Value: terraform.OutputContext(t, context.Background(), existingTerraformOptions, "cluster_resource_group_id"), DataType: "string"},
		{Name: "enable_auto_protect", Value: "false", DataType: "bool"},
		// {Name: "existing_brs_instance_crn", Value: permanentResources["brs_us_east_crn"], DataType: "string"},
		{Name: "existing_brs_instance_crn", Value: existing_brs_instance_crn, DataType: "string"},
		{Name: "brs_connection_name", Value: terraform.OutputContext(t, context.Background(), existingTerraformOptions, "brs_connection_name"), DataType: "string"},
		{Name: "brs_endpoint_type", Value: "public", DataType: "string"},
		{Name: "cluster_config_endpoint_type", Value: "private", DataType: "string"},
		{Name: "dsc_replicas", Value: "1", DataType: "number"},
		{Name: "brs_create_new_connection", Value: "false", DataType: "bool"},
		{Name: "region", Value: terraform.OutputContext(t, context.Background(), existingTerraformOptions, "region"), DataType: "string"},
		{Name: "connection_env_type", Value: "kRoksVpc", DataType: "string"},
		{Name: "kube_type", Value: "openshift", DataType: "string"},
		{Name: "policies", Value: []map[string]interface{}{
			{
				"name":              fmt.Sprintf("%s-test-policy", prefix),
				"create_new_policy": true,
				"schedule": map[string]interface{}{
					"unit": "Hours",
					"hour_schedule": map[string]interface{}{
						"frequency": 6,
					},
				},
				"retention": map[string]interface{}{
					"duration": 4,
					"unit":     "Weeks",
				},
				"use_default_backup_target": true,
			},
		}, DataType: "list"},
	}
}

func TestRunFullyConfigurableInSchematics(t *testing.T) {
	t.Parallel()

	tarIncludePatterns, recurseErr := getTarIncludePatternsRecursively("..", excludeDirs, includeFiletypes)
	// if error producing tar patterns (very unexpected) fail test immediately
	require.NoError(t, recurseErr, "Schematic Test had unexpected error traversing directory tree")

	// Provision resources first
	prefix := fmt.Sprintf("ocp-brs-%s", strings.ToLower(random.UniqueID()))
	existingTerraformOptions := setupTerraform(t, prefix, "./resources")
	defer cleanupTerraform(t, existingTerraformOptions, prefix)

	options := testschematic.TestSchematicOptionsDefault(&testschematic.TestSchematicOptions{
		Testing:               t,
		Prefix:                "ocp-fc",
		TarIncludePatterns:    tarIncludePatterns,
		TemplateFolder:        fullyConfigurableTerraformDir,
		Tags:                  []string{"test-schematic"},
		DeleteWorkspaceOnFail: false,
	})

	options.TerraformVars = getSchematicTerraformVars(t, prefix, options, existingTerraformOptions)
	options.IgnoreUpdates = testhelper.Exemptions{
		List: []string{
			// The DSC helm release re-updates on every plan because the BRS
			// registration token rotates by design and the chart version resolves
			// dynamically. This is expected, non-destructive churn.
			"module.protect_cluster.helm_release.data_source_connector",
			// wait_before_helm_destroy stores the kubeconfig path in input for its
			// destroy-time provisioner. That path differs between Schematics jobs
			// (each runs in a fresh temp dir), causing a side-effect-free in-place
			// update (no provisioner runs on update).
			"module.protect_cluster.terraform_data.wait_before_helm_destroy",
			// wait_for_dsc_node_ready stores the kubeconfig path in input.
			// That path differs between Schematics jobs (each runs in a fresh
			// temp dir), causing a side-effect-free in-place update.
			"module.protect_cluster.terraform_data.wait_for_dsc_node_ready[0]",
		},
	}
	// Skip the Schematics pre-destroy refresh AND the actual destroy refresh.
	//
	// Schematics runs "terraform refresh" before every destroy job. In Terraform
	// 1.12 "terraform refresh" is an alias for "terraform apply -refresh-only
	// -auto-approve", so TF_CLI_ARGS_apply affects it. Passing -refresh=false
	// makes that pre-destroy refresh a no-op, which prevents the IBM provider's
	// CustomizeDiff on ibm_backup_recovery_connection_registration_token from
	// firing and hard-erroring during the refresh step.
	//
	// TF_CLI_ARGS_apply=-refresh=false is safe here: the workspace is freshly
	// created for each test run and the apply creates all resources from scratch,
	// so there is no prior state to reconcile during apply. The token is
	// generated by a time_rotating + token resource chain that does not require
	// a live provider read to produce its initial value.
	//
	// TF_CLI_ARGS_destroy=-refresh=false skips the inline refresh inside the
	// destroy command itself (a separate code path from the pre-destroy refresh).
	//
	// Both can be removed once
	// https://github.com/IBM-Cloud/terraform-provider-ibm/pull/6906 is merged
	// and a new provider version is released.
	options.AddWorkspaceEnvVar("TF_CLI_ARGS_apply", "-refresh=false", false, false)
	options.AddWorkspaceEnvVar("TF_CLI_ARGS_destroy", "-refresh=false", false, false)
	require.NoError(t, options.RunSchematicTest(), "This should not have errored")
}

// Upgrade Test does not require KMS encryption
func TestRunUpgradeFullyConfigurable(t *testing.T) {
	t.Parallel()

	tarIncludePatterns, recurseErr := getTarIncludePatternsRecursively("..", excludeDirs, includeFiletypes)
	// if error producing tar patterns (very unexpected) fail test immediately
	require.NoError(t, recurseErr, "Schematic Test had unexpected error traversing directory tree")

	// Provision existing resources first
	prefix := fmt.Sprintf("ocp-existing-%s", strings.ToLower(random.UniqueID()))
	existingTerraformOptions := setupTerraform(t, prefix, "./resources")
	defer cleanupTerraform(t, existingTerraformOptions, prefix)

	options := testschematic.TestSchematicOptionsDefault(&testschematic.TestSchematicOptions{
		Testing:               t,
		Prefix:                "fc-upg",
		TarIncludePatterns:    tarIncludePatterns,
		TemplateFolder:        fullyConfigurableTerraformDir,
		Tags:                  []string{"test-schematic"},
		DeleteWorkspaceOnFail: false,
	})

	// Use create_new_connection=true for the upgrade test so the base apply
	// (which runs old v1.10.4 code) takes the ibm_backup_recovery_data_source_connection
	// creation path instead of the data-source lookup path.  With create_new_connection=false
	// the old module indexes data.ibm_backup_recovery_data_source_connections.connections[0].connections[0]
	// directly, which panics when BRS returns a null connections array (a known v1.10.4 bug
	// fixed in v1.12.2 via try()).  Schematics caches .terraform/ between the base apply and
	// the upgrade plan, so the cached v1.10.4 module would also be used during the plan step.
	vars := getSchematicTerraformVars(t, prefix, options, existingTerraformOptions)
	for i, v := range vars {
		if v.Name == "brs_create_new_connection" {
			vars[i].Value = "true"
		}
		if v.Name == "brs_connection_name" {
			vars[i].Value = fmt.Sprintf("%s-upgrade-conn", prefix)
		}
	}
	options.TerraformVars = vars

	options.IgnoreDestroys = testhelper.Exemptions{
		List: []string{
			"module.protect_cluster.time_rotating.token_rotation",
			"module.protect_cluster.ibm_backup_recovery_connection_registration_token.registration_token",
			"module.protect_cluster.terraform_data.cleanup_brs_agent_resources",
			"module.protect_cluster.module.backup_recovery_instance.ibm_backup_recovery_connection_registration_token.registration_token[0]",
			fmt.Sprintf(`module.protect_cluster.module.backup_recovery_instance.ibm_backup_recovery_protection_policy.protection_policy["%s-test-policy"]`, prefix),
			// wait_before_helm_destroy moved from triggers_replace to input, which
			// is a one-time structural change that forces a replace when upgrading
			// from the base version. Post-merge this becomes a plain in-place update
			// (covered by IgnoreUpdates below).
			"module.protect_cluster.terraform_data.wait_before_helm_destroy",
		},
	}
	options.IgnoreAdds = testhelper.Exemptions{
		List: []string{
			"module.protect_cluster.module.backup_recovery_instance.ibm_backup_recovery_connection_registration_token.registration_token[0]",
			"module.protect_cluster.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]",
			fmt.Sprintf(`module.protect_cluster.module.backup_recovery_instance.ibm_backup_recovery_protection_policy.protection_policy["%s-test-policy"]`, prefix),
			// wait_for_dsc_node_ready is a new resource added in this PR that
			// does not exist in the base version. The upgrade plan will show it
			// as an add, which is expected and harmless.
			"module.protect_cluster.terraform_data.wait_for_dsc_node_ready[0]",
		},
	}
	options.IgnoreUpdates = testhelper.Exemptions{
		List: []string{
			// The DSC helm release re-updates on every plan because the BRS
			// registration token rotates by design and the chart version resolves
			// dynamically. This is expected, non-destructive churn.
			"module.protect_cluster.helm_release.data_source_connector",
			// wait_before_helm_destroy stores the kubeconfig path in input for its
			// destroy-time provisioner. That path differs between Schematics jobs
			// (each runs in a fresh temp dir), causing a side-effect-free in-place
			// update (no provisioner runs on update).
			"module.protect_cluster.terraform_data.wait_before_helm_destroy",
			// wait_for_dsc_node_ready stores the kubeconfig path in input.
			// That path differs between Schematics jobs (each runs in a fresh
			// temp dir), causing a side-effect-free in-place update.
			"module.protect_cluster.terraform_data.wait_for_dsc_node_ready[0]",
		},
	}

	// Skip the pre-destroy terraform refresh and the destroy-inline refresh.
	//
	// Schematics runs "terraform refresh" (= "terraform apply -refresh-only
	// -auto-approve" in TF 1.12) before every destroy job. TF_CLI_ARGS_apply
	// propagates into that pre-destroy refresh step and makes it a no-op,
	// preventing the IBM provider from hard-erroring on a stale or missing
	// ibm_backup_recovery_data_source_connection entry in state (which happens
	// when the APPLY itself failed before creating the connection).
	//
	// This is safe for the upgrade test: the base apply creates a fresh
	// workspace with no existing state, and the upgrade apply re-applies to
	// in-place update resources — neither needs a live provider refresh since
	// all managed objects are known from state or newly created.
	//
	// Both vars can be removed once
	// https://github.com/IBM-Cloud/terraform-provider-ibm/pull/6906 is merged
	// and a new provider version is released.
	options.AddWorkspaceEnvVar("TF_CLI_ARGS_apply", "-refresh=false", false, false)
	options.AddWorkspaceEnvVar("TF_CLI_ARGS_destroy", "-refresh=false", false, false)
	require.NoError(t, options.RunSchematicUpgradeTest(), "This should not have errored")
}

// Shared setup function for all examples
func setupOptions(t *testing.T, prefix string, dir string, exemptionList []string) *testhelper.TestOptions {
	region := validRegions[common.CryptoIntn(len(validRegions))]
	options := testhelper.TestOptionsDefaultWithVars(&testhelper.TestOptions{
		Testing:       t,
		TerraformDir:  dir,
		Prefix:        prefix,
		ResourceGroup: resourceGroup,
		Region:        region,
		IgnoreUpdates: testhelper.Exemptions{
			List: exemptionList,
		},
	})

	if options.TerraformVars == nil {
		options.TerraformVars = map[string]interface{}{}
	}
	// options.TerraformVars["existing_brs_instance_crn"] = permanentResources["brs_us_east_crn"]
	options.TerraformVars["existing_brs_instance_crn"] = existing_brs_instance_crn

	return options
}

func TestRunIKSExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-iks", iksExampleDir, []string{
		"module.backup_recover_protect_ocp.ibm_backup_recovery_source_registration.source_registration",
		"ibm_container_vpc_cluster.vpc_cluster[0]",
		"ibm_container_cluster.cluster[0]",
	})
	// Skip refresh on consistency plan and destroy: stale BRS connection IDs in state
	// cause the provider to hard-error when BRS returns "does not exist" (not HTTP 404).
	// PostApplyHook fires after apply but before the consistency plan, so it can inject
	// -refresh=false into Plan args. PreDestroyHook covers the destroy.
	// Remove both once https://github.com/IBM-Cloud/terraform-provider-ibm/pull/6906
	// is merged and a new provider version is released.
	options.PostApplyHook = func(o *testhelper.TestOptions) error {
		o.TerraformOptions.ExtraArgs.Plan = append(o.TerraformOptions.ExtraArgs.Plan, "-refresh=false")
		return nil
	}
	options.PreDestroyHook = func(o *testhelper.TestOptions) error {
		// Remove stale BRS connection from state before destroy. The provider's
		// Delete hard-errors with HTTP 400 "does not exist" when the connection is
		// already gone server-side (provider bug; fix pending PR #6906). Ignore
		// the exit code — a non-zero means the resource wasn't in state, which is fine.
		terraform.RunTerraformCommandContextE(t, context.Background(), o.TerraformOptions, "state", "rm", //nolint:errcheck
			"module.backup_recover_protect_iks.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
		o.TerraformOptions.ExtraArgs.Destroy = append(o.TerraformOptions.ExtraArgs.Destroy, "-refresh=false")
		return nil
	}

	output, err := options.RunTestConsistency()
	assert.NoError(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}

func TestRunOCPExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-ocp", ocpExampleDir, []string{
		"module.backup_recover_protect_ocp.ibm_backup_recovery_source_registration.source_registration",
		"module.ocp_base[0].ibm_container_vpc_cluster.cluster[0]",
		"ibm_container_cluster.cluster[0]",
	})
	// Skip refresh on consistency plan and destroy: stale BRS connection IDs in state
	// cause the provider to hard-error when BRS returns "does not exist" (not HTTP 404).
	// PostApplyHook fires after apply but before the consistency plan, so it can inject
	// -refresh=false into Plan args. PreDestroyHook covers the destroy.
	// Remove both once https://github.com/IBM-Cloud/terraform-provider-ibm/pull/6906
	// is merged and a new provider version is released.
	options.PostApplyHook = func(o *testhelper.TestOptions) error {
		o.TerraformOptions.ExtraArgs.Plan = append(o.TerraformOptions.ExtraArgs.Plan, "-refresh=false")
		return nil
	}
	options.PreDestroyHook = func(o *testhelper.TestOptions) error {
		// Remove stale BRS connection from state before destroy (same reason as IKS above).
		terraform.RunTerraformCommandContextE(t, context.Background(), o.TerraformOptions, "state", "rm", //nolint:errcheck
			"module.backup_recover_protect_ocp.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
		o.TerraformOptions.ExtraArgs.Destroy = append(o.TerraformOptions.ExtraArgs.Destroy, "-refresh=false")
		return nil
	}

	output, err := options.RunTestConsistency()
	assert.NoError(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}

func TestRunCrossClusterExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-cross", crossClusterExampleDir, []string{
		"module.source_backup_recovery.ibm_backup_recovery_source_registration.source_registration",
		"module.target_backup_recovery.ibm_backup_recovery_source_registration.source_registration",
		"module.source_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_connection_registration_token.registration_token[0]",
		"module.target_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_connection_registration_token.registration_token[0]",
		"ibm_container_vpc_cluster.source_cluster[0]",
		"ibm_container_vpc_cluster.target_cluster[0]",
	})

	options.TerraformVars["brs_create_new_connection"] = true

	options.IgnoreUpdates.List = append(options.IgnoreUpdates.List,
		fmt.Sprintf(`module.source_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_protection_policy.protection_policy["%s-continuous-backup"]`, options.Prefix),
	)
	// Skip refresh on consistency plan and destroy: stale BRS connection IDs in state
	// cause the provider to hard-error when BRS returns "does not exist" (not HTTP 404).
	// PostApplyHook fires after apply but before the consistency plan, so it can inject
	// -refresh=false into Plan args. PreDestroyHook covers the destroy.
	// Remove both once https://github.com/IBM-Cloud/terraform-provider-ibm/pull/6906
	// is merged and a new provider version is released.
	options.PostApplyHook = func(o *testhelper.TestOptions) error {
		o.TerraformOptions.ExtraArgs.Plan = append(o.TerraformOptions.ExtraArgs.Plan, "-refresh=false")
		return nil
	}
	options.PreDestroyHook = func(o *testhelper.TestOptions) error {
		// Remove stale BRS connections (source + target) from state before destroy.
		terraform.RunTerraformCommandContextE(t, context.Background(), o.TerraformOptions, "state", "rm", //nolint:errcheck
			"module.source_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
		terraform.RunTerraformCommandContextE(t, context.Background(), o.TerraformOptions, "state", "rm", //nolint:errcheck
			"module.target_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
		// Use parallelism=1 so cluster worker-node cleanup finishes before
		// Terraform attempts to delete the VPCs and subnets.
		o.TerraformOptions.ExtraArgs.Destroy = append(o.TerraformOptions.ExtraArgs.Destroy, "-refresh=false", "-parallelism=1")
		return nil
	}

	output, err := options.RunTestConsistency()
	assert.NoError(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}

func TestRunCrossClusterExistingConnection(t *testing.T) {
	t.Parallel()

	// Provision pre-existing BRS connections using dedicated helper directory
	prefix := fmt.Sprintf("brs-xc-%s", strings.ToLower(random.UniqueID()))
	existingTerraformOptions := setupTerraform(t, prefix, "./resources-cross-cluster")
	defer cleanupTerraform(t, existingTerraformOptions, prefix)

	// The cross-cluster example must run in the same region as the pre-provisioned
	// BRS connections so that brs_create_new_connection=false can locate them.
	// setupTerraform picks its own random region; read it back from the output.
	existingRegion := terraform.OutputContext(t, context.Background(), existingTerraformOptions, "region")

	options := setupOptions(t, prefix, crossClusterExampleDir, []string{
		"module.source_backup_recovery.ibm_backup_recovery_source_registration.source_registration",
		"module.target_backup_recovery.ibm_backup_recovery_source_registration.source_registration",
		"module.source_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_connection_registration_token.registration_token[0]",
		"module.target_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_connection_registration_token.registration_token[0]",
		"ibm_container_vpc_cluster.source_cluster[0]",
		"ibm_container_vpc_cluster.target_cluster[0]",
	})

	// Override the random region chosen by setupOptions with the one used for the
	// pre-provisioned connections so the two terraform states stay consistent.
	options.Region = existingRegion
	options.TerraformVars["region"] = existingRegion
	// options.TerraformVars["existing_brs_instance_crn"] = permanentResources["brs_us_east_crn"]
	options.TerraformVars["existing_brs_instance_crn"] = existing_brs_instance_crn
	options.TerraformVars["brs_create_new_connection"] = false
	options.TerraformVars["source_connection_name"] = terraform.OutputContext(t, context.Background(), existingTerraformOptions, "source_connection_name")
	options.TerraformVars["target_connection_name"] = terraform.OutputContext(t, context.Background(), existingTerraformOptions, "target_connection_name")

	// The continuous-backup protection policy re-plans as an in-place update on the
	// consistency check: its backup_policy value churns by design, so the second plan
	// always shows a no-op update. Exempt it, exactly as TestRunCrossClusterExample does.
	options.IgnoreUpdates.List = append(options.IgnoreUpdates.List,
		fmt.Sprintf(`module.source_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_protection_policy.protection_policy["%s-continuous-backup"]`, options.Prefix),
	)

	options.PostApplyHook = func(o *testhelper.TestOptions) error {
		o.TerraformOptions.ExtraArgs.Plan = append(o.TerraformOptions.ExtraArgs.Plan, "-refresh=false")
		return nil
	}
	options.PreDestroyHook = func(o *testhelper.TestOptions) error {
		terraform.RunTerraformCommandContextE(t, context.Background(), o.TerraformOptions, "state", "rm", //nolint:errcheck
			"module.source_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
		terraform.RunTerraformCommandContextE(t, context.Background(), o.TerraformOptions, "state", "rm", //nolint:errcheck
			"module.target_backup_recovery.module.backup_recovery_instance.ibm_backup_recovery_data_source_connection.connection[0]")
		// Use parallelism=1 on destroy so that IBM cluster worker nodes finish
		// draining before Terraform attempts to delete the VPC and its subnets.
		// Without this the VPC destroy races the asynchronous worker-node cleanup
		// and fails with "VPC is in use" even after the subnet resource is gone.
		o.TerraformOptions.ExtraArgs.Destroy = append(o.TerraformOptions.ExtraArgs.Destroy, "-refresh=false", "-parallelism=1")
		return nil
	}

	output, err := options.RunTestConsistency()
	assert.NoError(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}
