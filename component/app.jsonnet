local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('openshift4-nodes', params.machineApiNamespace);

local appPath =
  local project = std.get(app, 'spec', { project: 'syn' }).project;
  if project == 'syn' then 'apps' else 'apps-%s' % project;

{
  ['%s/openshift4-nodes' % appPath]: app,
}
