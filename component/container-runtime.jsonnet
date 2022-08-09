local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local containerRuntimeConfigs = [
  kube._Object('machineconfiguration.openshift.io/v1', 'ContainerRuntimeConfig', nodeGroup) {
    metadata+: {
      labels+: common.DefaultLabels,
    },
    spec: params.containerRuntimeConfigs[nodeGroup],
  }
  for nodeGroup in std.objectFields(params.containerRuntimeConfigs)
  if params.containerRuntimeConfigs[nodeGroup] != null
];

{
  [if std.length(containerRuntimeConfigs) > 0 then '20_containerruntimeconfigs']: containerRuntimeConfigs,
}
