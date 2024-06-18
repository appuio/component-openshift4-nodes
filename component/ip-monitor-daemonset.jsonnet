local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;

local command = 'ip -ts monitor address link mroute netconf nexthop nsid prefix route rule';

// what do we need:
// namespace
// serviceaccount
// rolebinding for scc hostnetwork
// daemonset which has hostNetwork: true and which runs the comment

local namespace = 'appuio-ip-monitor';

local ns = kube.Namespace('appuio-ip-monitor') {
  metadata+: {
    annotations+: {
      'openshift.io/node-selector': '',
    },
    labels+: {
      'openshift.io/cluster-monitoring': 'true',
    },
  },
};

local sa = kube.ServiceAccount('ip-monitor') {
  metadata+: {
    namespace: namespace,
  },
};

local sccRoleBinding = kube.RoleBinding('ip-monitor-scc-hostnetwork') {
  metadata+: {
    namespace: namespace,
  },
  subjects_: [ sa ],
  roleRef: {
    kind: 'ClusterRole',
    name: 'system:openshift:scc:hostnetwork-v2',
  },
};

local ds = kube.DaemonSet('ip-monitor') {
  metadata+: {
    namespace: namespace,
  },
  spec+: {
    template+: {
      spec+: {
        containers_+: {
          ipmon: kube.Container('ip-monitor') {
            image: 'image-registry.openshift-image-registry.svc:5000/openshift/tools:latest',
            command: [ '/bin/sh', '-c', 'trap : TERM INT; %s & wait' % command ],
          },
        },
        hostNetwork: true,
        priorityClassName: 'system-node-critical',
        // run on all nodes
        tolerations: [
          { operator: 'Exists' },
        ],
        serviceAccountName: sa.metadata.name,
      },
    },
  },
};

{
  '40_ip_monitor': [
    ns,
    sa,
    sccRoleBinding,
    ds,
  ],
}
