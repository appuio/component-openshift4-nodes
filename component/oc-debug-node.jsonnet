local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;
{
  [if params.debugNamespace != null then 'debug']:
    kube.Namespace(params.debugNamespace) {
      metadata+: {
        annotations+: {
          // Override the default node selector, so pods can be scheduled on
          // any node
          'openshift.io/node-selector': '',
          // Tolerate all taints when scheduling pods.
          // As documented in https://access.redhat.com/solutions/4976641
          'scheduler.alpha.kubernetes.io/defaultTolerations': '[{"operator":"Exists"}]',
        },
      },
    },
}
