local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('openshift4-nodes', params.machineApiNamespace) {
  spec+: {
    ignoreDifferences: [
      {
        kind: 'ControlPlaneMachineSet',
        name: 'cluster',
        namespace: params.machineApiNamespace,
        jsonPointers: [
          '/spec/state',
        ],
      },
    ],
  },
};

{
  'openshift4-nodes': app,
}
