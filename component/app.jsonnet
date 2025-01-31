local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;
local argocd = import 'lib/argocd.libjsonnet';

local autoscaler = import 'autoscaler.jsonnet';

local app = argocd.App('openshift4-nodes', params.machineApiNamespace) {
  spec+: {
    ignoreDifferences+: autoscaler.ignoreDifferences,
    syncPolicy+: {
      syncOptions+: [
        'RespectIgnoreDifferences=true',
      ],
    },
  },
};

local appPath =
  local project = std.get(std.get(app, 'spec', {}), 'project', 'syn');
  if project == 'syn' then 'apps' else 'apps-%s' % project;

{
  ['%s/openshift4-nodes' % appPath]: app,
}
