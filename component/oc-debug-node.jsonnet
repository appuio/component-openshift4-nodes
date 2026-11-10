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
        labels+: {
          // Disable OpenShift's automatic PSS label sync, since we don't have
          // any service accounts that can use an SCC that would need PSS
          // privileged and want to manage the PSS labels ourselves.
          'security.openshift.io/scc.podSecurityLabelSync': 'false',
          // Set PSS privileged, which is required for the `oc debug node`
          // pods.
          'pod-security.kubernetes.io/enforce': 'privileged',
          'pod-security.kubernetes.io/audit': 'privileged',
          'pod-security.kubernetes.io/warn': 'privileged',
        },
      },
    },
}
