local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;

local getConfigs(parameter) =
  std.foldl(
    function(configs, name)
      local pool = params.machineConfigPools[name];
      configs {
        [if std.objectHas(pool, parameter) then name]: pool[parameter] {
          machineConfigPoolSelector: {
            matchExpressions: [
              {
                key: 'pools.operator.machineconfiguration.openshift.io/%s' % name,
                operator: 'Exists',
              },
            ],
          },
        },
      },
    std.objectFields(params.machineConfigPools),
    {}
  );

local kubelet = getConfigs('kubelet');
local containerRuntime = getConfigs('containerRuntime');

{
  KubeletConfigs: kubelet,
  ContainerRuntimeConfigs: containerRuntime,
}
