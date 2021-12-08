local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.control_api;

{
  DefaultLabels: {
    'app.kubernetes.io/name': 'openshift4-nodes',
    'app.kubernetes.io/component': 'openshift4-nodes',
    'app.kubernetes.io/managed-by': 'commodore',
  },
}
