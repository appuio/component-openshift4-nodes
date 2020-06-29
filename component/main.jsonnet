local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.openshift4_nodes;

local machine = function(name) com.namespaced('openshift-machine-api', kube._Object('machine.openshift.io/v1beta1', 'MachineSet', name) {
  metadata+: {
    labels+: {
      'machine.openshift.io/cluster-api-cluster': params.clusterId,
    },
  },
});


local machines = [
  machine(name)
  for name in std.objectFields(params.nodeGroups)
];

// Define outputs below
{
  '01_machines': machines,
}
