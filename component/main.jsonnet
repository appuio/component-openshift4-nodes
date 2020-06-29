local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

// The hiera parameters for the component
local params = inv.parameters.openshift4_nodes;

local machine = function(name, spec)
  local machineSpec = if std.objectHas(spec, 'spec') then spec.spec else {};
  com.namespaced('openshift-machine-api', kube._Object('machine.openshift.io/v1beta1', 'MachineSet', name) {
    metadata+: {
      labels+: {
        'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
      },
    },
    spec: {
      replicas: if std.objectHas(spec, 'replicas') then spec.replicas else 1,
      selector: {
        matchLabels: {
          'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
          'machine.openshift.io/cluster-api-machineset': name,
        },
      },
      template: {
        metadata: {
          creationTimestamp: null,
          labels: {
            'machine.openshift.io/cluster-api-cluster': params.infrastructureID,
            'machine.openshift.io/cluster-api-machine-role': 'worker',
            'machine.openshift.io/cluster-api-machine-type': 'worker',
            'machine.openshift.io/cluster-api-machineset': name,
          },
        },
        spec: {
          metadata: {
            creationTimestamp: null,
          },
          providerSpec+: {
            value+: {
              apiVersion: 'gcpprovider.openshift.io/v1beta1',
              canIPForward: false,
              credentialsSecret: {
                name: 'gcp-cloud-credentials',
              },
              deletionProtection: false,
              disks: [
                {
                  autoDelete: true,
                  boot: true,
                  image: params.infrastructureID + '-rhcos-image',
                  labels: null,
                  sizeGb: 128,
                  type: 'pd-ssd',
                },
              ],
              kind: 'GCPMachineProviderSpec',
              machineType: spec.instanceType,
              metadata: {
                creationTimestamp: null,
              },
              networkInterfaces: [
                {
                  network: params.infrastructureID + '-network',
                  subnetwork: params.infrastructureID + '-worker-subnet',
                },
              ],
              projectID: params.projectName,
              region: params.region,
              serviceAccounts: [
                {
                  email: params.infrastructureID + '-w@' + params.projectName + '.iam.gserviceaccount.com',
                  scopes: [
                    'https://www.googleapis.com/auth/cloud-platform',
                  ],
                },
              ],
              tags: [
                params.infrastructureID + '-worker',
              ],
              userDataSecret: {
                name: 'worker-user-data',
              },
              zone: params.availabilityZones[0],
            },
          },
        } + machineSpec,
      },
    },
  });

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
      spec: {
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

local machines = [
  machine(m.name, m.spec)
  for m in machineSpecs
];

// Define outputs below
{
  '01_machines': machines,
}
