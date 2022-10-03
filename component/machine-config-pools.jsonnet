local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local common = import 'common.libsonnet';

local params = inv.parameters.openshift4_nodes;

local MachineConfigPool(name) = kube._Object('machineconfiguration.openshift.io/v1', 'MachineConfigPool', 'x-%s' % name) {
  metadata+: {
    labels+: common.DefaultLabels {
      ['pools.operator.machineconfiguration.openshift.io/%s' % name]: '',
    },
  },
  spec: {},
};

local PatchMachineConfigPool(name) = {
  local fallback(key, obj) = {
    [if !std.objectHas(super.spec, key) then key]: obj,
  },
  spec+:
    fallback(
      'machineConfigSelector', {
        matchExpressions: [
          {
            key: 'machineconfiguration.openshift.io/role',
            operator: 'In',
            values: [ 'worker', name ],
          },
        ],
      }
    ) +
    fallback(
      'nodeSelector', {
        matchLabels: {
          ['node-role.kubernetes.io/%s' % name]: '',
        },
      }
    ),
};


{
  [
  if
    name != 'master'
    && name != 'worker'
    && params.machineConfigPools[name] != null
  then
    'machineconfigpool-' + name
  ]:
    local rname = kube.hyphenate(name);
    MachineConfigPool(rname)
    + com.makeMergeable(params.machineConfigPools[name])
    + PatchMachineConfigPool(name)
  for name in std.objectFields(params.machineConfigPools)
}
