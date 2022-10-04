local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local mergedConfigs =
  std.foldl(
    function(configs, name)
      local pool = params.machineConfigPools[name];
      configs {
        [if std.objectHas(pool, 'containerRuntime') then name]: pool.containerRuntime,
      },
    std.objectFields(params.machineConfigPools),
    {}
  ) + com.makeMergeable(params.containerRuntimeConfigs);


local containerRuntimeConfigs = [

  kube._Object('machineconfiguration.openshift.io/v1', 'ContainerRuntimeConfig', nodeGroup) {
    local fallback(parent, key, obj) = {
      [if !std.objectHas(parent, key) then key]: obj,
    },
    metadata+: {
      labels+: common.DefaultLabels,
    },
    spec: mergedConfigs[nodeGroup] + fallback(mergedConfigs[nodeGroup], 'machineConfigPoolSelector', {
      matchExpressions: [
        {
          key: 'pools.operator.machineconfiguration.openshift.io/%s' % nodeGroup,
          operator: 'Exists',
        },
      ],
    }),
  }
  for nodeGroup in std.objectFields(mergedConfigs)
  if mergedConfigs[nodeGroup] != null
];

{
  [if std.length(containerRuntimeConfigs) > 0 then '20_containerruntimeconfigs']: containerRuntimeConfigs,
}
