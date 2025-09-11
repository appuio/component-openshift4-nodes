local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local isGCP = inv.parameters.facts.cloud == 'gcp';
local isCloudscale = inv.parameters.facts.cloud == 'cloudscale';
local isOpenstack = inv.parameters.facts.cloud == 'openstack';

local machineSetSpecs = function(name, set, role)
  kube._Object('machine.openshift.io/v1beta1', 'MachineSet', name) {
    spec+: params.defaultSpecs[inv.parameters.facts.cloud],
  } + {
    metadata+: {
      annotations+: com.getValueOrDefault(set, 'annotations', {}),
      labels+: {
        'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
      },
      namespace: params.machineApiNamespace,
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
          metadata+: {
            labels+: {
              'node-role.kubernetes.io/worker': '',
              [if role != 'worker' then 'node-role.kubernetes.io/' + role]: '',
            },
          },
          providerSpec+: (
            if isGCP then {
              value+: {
                machineType: set.instanceType,
                tags: [
                  params.infrastructureID + '-worker',
                ],
                zone: params.availabilityZones[0],
              },
            } else {}
          ) + (
            if isCloudscale then {
              value+: {
                antiAffinityKey: name,
              },
            } else {}
          ) + (
            if isOpenstack && std.objectHas(set, 'portSecurity') then {
              value+: {
                networks: [
                  n {
                    portSecurity: set.portSecurity,
                  }
                  for n in super.networks
                ],
              },
            }
            else {}
          ) + com.makeMergeable(std.get(set, 'providerSpec', {})),
        },
      },
    },
  };

local cpMachineSetSpecs = function(set)
  kube._Object('machine.openshift.io/v1', 'ControlPlaneMachineSet', 'cluster') {
    spec+: params.controlPlaneDefaultSpecs[inv.parameters.facts.cloud],
  } + {
    metadata+: {
      annotations+: std.get(set, 'annotations', {}),
      namespace: params.machineApiNamespace,
    },
    spec+: {
      replicas: std.get(set, 'replicas', 1),
      selector+: {
        matchLabels+: {
          'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
          'machine.openshift.io/cluster-api-machine-role': 'master',
          'machine.openshift.io/cluster-api-machine-type': 'master',
        },
      },
      state: 'Inactive',
      strategy+: {
        type: 'OnDelete',
      },
      template+: {
        machineType+: 'machines_v1beta1_machine_openshift_io',
        machines_v1beta1_machine_openshift_io+: {
          failureDomains+: {
            platform: '',
          },
          metadata+: {
            labels+: {
              'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
              'machine.openshift.io/cluster-api-machine-role': 'master',
              'machine.openshift.io/cluster-api-machine-type': 'master',
            },
          },
          spec+: {
            providerSpec+: (
              if isGCP then {
                value+: {
                  machineType: set.instanceType,
                  tags: [
                    params.infrastructureID + '-master',
                  ],
                  zone: params.availabilityZones[0],
                },
              } else {}
            ) + (
              if isCloudscale then {
                value+: {
                  antiAffinityKey: 'master',
                },
              } else {}
            ) + com.makeMergeable(std.get(set, 'providerSpec', {})),
          },
        },
      },
    },
  };

local machineSet = function(name, set)
  local role = std.get(set, 'role', name);
  local spec = com.makeMergeable(std.get(set, 'spec', {}));
  if role == 'master' then cpMachineSetSpecs(set) { spec+: spec }
  else machineSetSpecs(name, set, role) { spec+: spec };

local isMultiAz = function(name)
  com.getValueOrDefault(params.nodeGroups[name], 'multiAz', false);

local zoneId = function(name)
  std.reverse(std.split(name, '-'))[0];

local replicasPerZone(replicas) =
  std.ceil(replicas / std.length(params.availabilityZones));

local machineSpecs = [
  { name: name, spec: params.nodeGroups[name] }
  for name in std.objectFields(params.nodeGroups)
  if !isGCP || !isMultiAz(name)
] + std.flattenArrays([
  [
    {
      name: name + '-' + zoneId(zone),
      spec: params.nodeGroups[name] {
        replicas: replicasPerZone(com.getValueOrDefault(params.nodeGroups[name], 'replicas', 1)),
        spec+: {
          template+: {
            spec+: {
              providerSpec+: {
                value+: {
                  zone: zone,
                },
              },
            },
          },
        },
      },
    }
    for zone in params.availabilityZones
  ]
  for name in std.objectFields(params.nodeGroups)
  if isGCP && isMultiAz(name)
]);

local additionalMachineSets = com.generateResources(params.machineSets, function(name) kube._Object('machine.openshift.io/v1beta1', 'MachineSet', name) {
  metadata+: {
    namespace: params.machineApiNamespace,
  },
});

{
  ['machineset-' + m.name]: machineSet(m.name, m.spec)
  for m in machineSpecs
  if m.spec != null
} + {
  [if std.length(machineSpecs) == 0 && std.length(additionalMachineSets) == 0 then '.gitkeep']: {},
} + {
  [if std.length(additionalMachineSets) > 0 then 'additional_machine_sets']: additionalMachineSets,
}
