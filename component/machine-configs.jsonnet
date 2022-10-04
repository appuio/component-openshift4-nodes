local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;


local MachineConfig(name) = kube._Object('machineconfiguration.openshift.io/v1', 'MachineConfig', '99x-%s' % name) {
  metadata+: {
    labels+: common.DefaultLabels,
  },
};

local patchPoolConfig(pool, confs) =
  std.foldl(
    function(cs, c)
      local obj = confs[c];
      cs {
        ['%s-%s' % [ pool, c ]]: {
          metadata: {
            labels: {
              'machineconfiguration.openshift.io/role': pool,
            },
          },
          spec: obj,
        },
      }, std.objectFields(confs), {}
  );

local mergedConfigs =
  std.foldl(
    function(ps, p)
      local confs = std.get(params.machineConfigPools[p], 'machineConfigs', default={});
      ps + patchPoolConfig(p, confs),
    std.objectFields(params.machineConfigPools),
    {}
  )
  + com.makeMergeable(params.machineConfigs);

local machineConfigs = com.generateResources(mergedConfigs, MachineConfig);
{
  [if std.length(machineConfigs) > 0 then '10_machineconfigs']: machineConfigs,
}
