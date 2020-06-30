local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local machineSet = function(name, set)
  local role = if std.objectHas(set, 'role') then set.role else 'worker';
  kube._Object('machine.openshift.io/v1beta1', 'MachineSet', name)
  + { spec+: params.defaultSpecs[inv.parameters.cloud.provider] }
  + {
    metadata+: {
      labels+: {
        'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
      },
      namespace: params.namespace,
    },
    spec+: {
      replicas: com.getValueOrDefault(set, 'replicas', 1),
      selector+: {
        matchLabels+: {
          'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
          'machine.openshift.io/cluster-api-machineset': name,
        },
      },
      template+: {
        metadata+: {
          labels+: {
            'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
            'machine.openshift.io/cluster-api-machine-role': role,
            'machine.openshift.io/cluster-api-machine-type': role,
            'machine.openshift.io/cluster-api-machineset': name,
          },
        },
        spec+: {
          providerSpec+: {
            value+: {
              machineType: set.instanceType,
              tags: [
                params.infrastructureID + '-' + role,
              ],
              zone: params.availabilityZones[0],
            },
          },
        },
      },
    },
  }
  + if std.objectHas(set, 'spec') then { spec+: com.makeMergeable(set.spec) } else {};

local isMultiAz = function(name)
  std.objectHas(params.nodeGroups[name], 'multiAz') && params.nodeGroups[name].multiAz == true;

local zoneId = function(name)
  std.reverse(std.split(name, '-'))[0];

local machineSpecs = [
  { name: name, spec: params.nodeGroups[name] }
  for name in std.objectFields(params.nodeGroups)
  if !isMultiAz(name)
] + std.flattenArrays([
  [
    local spec = {
      spec+: {
        providerSpec+: {
          value+: {
            zone: zone,
          },
        },
      },
    } + params.nodeGroups[name];
    { name: name + '-' + zoneId(zone), spec: spec }
    for zone in params.availabilityZones
  ]
  for name in std.objectFields(params.nodeGroups)
  if isMultiAz(name)
]);

local machineSets = [
  machineSet(m.name, m.spec)
  for m in machineSpecs
];

// Define outputs below
{
  '01_machinesets': machineSets,
}
