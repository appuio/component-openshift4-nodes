local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('openshift4-nodes', params.namespace);

{
  'openshift4-nodes': app,
}
