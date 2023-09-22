local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local nodeConfig = kube._Object('config.openshift.io/v1', 'Node', 'cluster') {
  spec: params.nodeConfig,
};

{
  '10_nodeconfig': nodeConfig,
}
