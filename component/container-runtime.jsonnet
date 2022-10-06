local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local machineConfigPools = import 'machine-config-pools.libsonnet';

local params = inv.parameters.openshift4_nodes;

local mergedConfigs = machineConfigPools.ContainerRuntimeConfigs + com.makeMergeable(params.containerRuntimeConfigs);

local containerRuntimeConfigs = [
  kube._Object('machineconfiguration.openshift.io/v1', 'ContainerRuntimeConfig', nodeGroup) {
    metadata+: {
      labels+: common.DefaultLabels,
    },
    spec: mergedConfigs[nodeGroup],
  }
  for nodeGroup in std.objectFields(mergedConfigs)
  if mergedConfigs[nodeGroup] != null
];

{
  [if std.length(containerRuntimeConfigs) > 0 then '20_containerruntimeconfigs']: containerRuntimeConfigs,
}
