local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local machineConfigPools = import 'machine-config-pools.libsonnet';

local params = inv.parameters.openshift4_nodes;

local mergedConfigs = machineConfigPools.MachineConfigs + com.makeMergeable(params.machineConfigs);

local MachineConfig(name) = kube._Object('machineconfiguration.openshift.io/v1', 'MachineConfig', '99x-%s' % name) {
  metadata+: {
    labels+: common.DefaultLabels,
  },
};

local machineConfigs = com.generateResources(mergedConfigs, MachineConfig);
{
  [if std.length(machineConfigs) > 0 then '10_machineconfigs']: machineConfigs,
}
