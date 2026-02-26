// Tests in this file are run in the PR pipeline and the continuous testing pipeline
package test

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// Ensure every example directory has a corresponding test
const ocpClassicExampleDir = "examples/openshift-classic"
const iksClassicExampleDir = "examples/kubernetes-classic"

func TestRunIKSClassicExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-iksc", iksClassicExampleDir, []string{
		"module.backup_recover_protect_ocp.ibm_backup_recovery_source_registration.source_registration",
		"ibm_container_vpc_cluster.cluster[0]",
		"ibm_container_cluster.cluster[0]",
	})

	output, err := options.RunTestConsistency()
	assert.Nil(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}

func TestRunOCPClassicExample(t *testing.T) {
	t.Parallel()

	options := setupOptions(t, "brs-ocpc", ocpClassicExampleDir, []string{
		"module.backup_recover_protect_ocp.ibm_backup_recovery_source_registration.source_registration",
		"module.ocp_base[0].ibm_container_vpc_cluster.cluster[0]",
		"ibm_container_cluster.cluster[0]",
	})

	output, err := options.RunTestConsistency()
	assert.Nil(t, err, "This should not have errored")
	assert.NotNil(t, output, "Expected some output")
}
