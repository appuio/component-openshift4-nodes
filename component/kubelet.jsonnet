local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local kubeletConfigs = [
  kube._Object('machineconfiguration.openshift.io/v1', 'KubeletConfig', nodeGroup) {
    metadata+: {
      labels+: common.DefaultLabels,
    },
    spec: params.kubeletConfigs[nodeGroup],
  }
  for nodeGroup in std.objectFields(params.kubeletConfigs)
  if params.kubeletConfigs[nodeGroup] != null
];

{
  [if std.length(kubeletConfigs) > 0 then '10_kubeletconfigs']: kubeletConfigs,
}
