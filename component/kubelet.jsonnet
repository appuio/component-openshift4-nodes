local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local machineConfigPools = import 'machine-config-pools.libsonnet';

local params = inv.parameters.openshift4_nodes;

local checkMaxPods(config) =
  if
    std.objectHas(config.kubeletConfig, 'maxPods')
    && config.kubeletConfig.maxPods > 110
  then
    config {
      kubeletConfig: {
        maxPods: std.trace(
          '[WARNING] Upstream Kubernetes recommends to have maximum pods per node <= 110.',
          config.kubeletConfig.maxPods
        ),
      },
    }
  else
    config;


local kubeletConfig(name) = kube._Object('machineconfiguration.openshift.io/v1', 'KubeletConfig', name) {
  metadata+: {
    labels+: common.DefaultLabels,
  },
};

local mergedConfigs = machineConfigPools.KubeletConfigs + com.makeMergeable(params.kubeletConfigs);

local kubeletConfigs = [
  kubeletConfig(nodeGroup) {
    spec: checkMaxPods(mergedConfigs[nodeGroup]),
  }
  for nodeGroup in std.objectFields(mergedConfigs)
  if mergedConfigs[nodeGroup] != null
];

{
  [if std.length(kubeletConfigs) > 0 then '10_kubeletconfigs']: kubeletConfigs,
}
