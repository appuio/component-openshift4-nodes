local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.control_api;

local defaultLabels = {
  'app.kubernetes.io/name': 'openshift4-nodes',
  'app.kubernetes.io/component': 'openshift4-nodes',
  'app.kubernetes.io/managed-by': 'commodore',
};

local MachineConfig(name) =
  kube._Object('machineconfiguration.openshift.io/v1', 'MachineConfig', '99x-%s' % name) {
    metadata+: {
      labels+: defaultLabels,
    },
  };


{
  DefaultLabels: defaultLabels,
  MachineConfig: MachineConfig,
}
