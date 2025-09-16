local kube = import 'lib/kube.libjsonnet';

{
  '01_aggregated_clusterroles': [
    kube.ClusterRole('syn-openshift4-nodes-cluster-reader') {
      metadata+: {
        labels+: {
          'rbac.authorization.k8s.io/aggregate-to-cluster-reader': 'true',
        },
      },
      rules: [
        {
          apiGroups: [ 'machineconfiguration.openshift.io' ],
          resources: [ 'machineconfigs' ],
          verbs: [
            'get',
            'list',
            'watch',
          ],
        },
        {
          apiGroups: [ 'machine.openshift.io' ],
          resources: [ 'controlplanemachinesets' ],
          verbs: [
            'get',
            'list',
            'watch',
          ],
        },
      ],
    },
  ],
}
