// Tests in this file are run in the PR pipeline and the continuous testing pipeline
package test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/terraform-ibm-modules/ibmcloud-terratest-wrapper/testhelper"
)

// Ensure every example directory has a corresponding test
const ocpExampleDir = "examples/openshift"
const iksExampleDir = "examples/kubernetes"

var region = "us-east"

// ibm_backup_recovery_source_registration requires ignoring updates to kubernetes_params fields which will be fixed in future provider versions
func setupOptions(t *testing.T, prefix string, dir string) *testhelper.TestOptions {
	options := testhelper.TestOptionsDefaultWithVars(&testhelper.TestOptions{
		Testing:       t,
		TerraformDir:  dir,
		Prefix:        prefix,
		ResourceGroup: resourceGroup,
		Region:        region,
		IgnoreUpdates: testhelper.Exemptions{
			List: []string{"module.protect_cluster.ibm_backup_recovery_source_registration.source_registration",
				"module.protect_cluster.kubernetes_service_account_v1.brsagent",
				"module.protect_cluster.helm_release.data_source_connector",
				"module.protect_cluster.terraform_data.delete_auto_protect_pg"},
		},
	})
	return options
}

func TestRunOCPExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs", ocpExampleDir)

	output, err := options.RunTestConsistency()
	assert.Nil(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}

func TestRunUpgradeExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-upg", ocpExampleDir)

	output, err := options.RunTestUpgrade()
	if !options.UpgradeTestSkipped {
		assert.Nil(t, err, "This should not have errored")
		assert.NotNil(t, output, "Expected some output")
	}
}

func TestRunIKSExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-adv", iksExampleDir)

	output, err := options.RunTestConsistency()
	assert.Nil(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}
