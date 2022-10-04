local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

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

local mergedConfigs =
  std.foldl(
    function(configs, name)
      local pool = params.machineConfigPools[name];
      configs {
        [if std.objectHas(pool, 'kubelet') then name]: pool.kubelet,
      },
    std.objectFields(params.machineConfigPools),
    {}
  ) + com.makeMergeable(params.kubeletConfigs);

local kubeletConfigs = [
  local fallback(parent, key, obj) = {
    [if !std.objectHas(parent, key) then key]: obj,
  };
  local spec = checkMaxPods(mergedConfigs[nodeGroup]);
  kubeletConfig(nodeGroup) {
    spec: spec + fallback(spec, 'machineConfigPoolSelector', {
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
  [if std.length(kubeletConfigs) > 0 then '10_kubeletconfigs']: kubeletConfigs,
}
