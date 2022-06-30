local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local prometheus = import 'lib/prometheus.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;

local namespaces = [
  'openshift-machine-api',
  'openshift-machine-config-operator',
];

local syn_metrics =
  params.monitoring.enabled &&
  std.member(inv.applications, 'prometheus');

// config to drop Go runtime and Prometheus http handler metrics
local dropRuntimeMetrics = {
  action: 'drop',
  regex: '(go_.*|process_.*|promhttp_.*)',
  sourceLabels: [ '__name__' ],
};

local endpointDefaults = {
  bearerTokenFile: '/var/run/secrets/kubernetes.io/serviceaccount/token',
  interval: '30s',
  scheme: 'https',
  relabelings: [
    dropRuntimeMetrics,
  ],
  tlsConfig: {
    caFile: '/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt',
  },
};
local smDefaults(ns, name) = {
  spec: {
    namespaceSelector: {
      matchNames: [ ns ],
    },
    selector: {
      matchLabels: {
        'k8s-app': name,
      },
    },
  },
};

local serviceMonitors = {
  'openshift-machine-api': [
    {
      name: 'cluster-autoscaler-operator',
      config: smDefaults('openshift-machine-api', 'cluster-autoscaler-operator') {
        spec+: {
          endpoints: [
            endpointDefaults {
              port: 'metrics',
              tlsConfig+: {
                serverName: 'cluster-autoscaler-operator.openshift-machine-api.svc',
              },
            },
          ],
        },
      },
    },
    {
      name: 'machine-api-controllers',
      config: smDefaults('openshift-machine-api', 'controller') {
        spec+: {
          endpoints: [
            endpointDefaults {
              port: 'machine-mtrc',
              scheme: 'https',
              tlsConfig+: {
                serverName: 'machine-api-controllers.openshift-machine-api.svc',
              },
            },
            endpointDefaults {
              port: 'machineset-mtrc',
              tlsConfig+: {
                serverName: 'machine-api-controllers.openshift-machine-api.svc',
              },
            },
            endpointDefaults {
              port: 'mhc-mtrc',
              scheme: 'https',
              tlsConfig+: {
                serverName: 'machine-api-controllers.openshift-machine-api.svc',
              },
            },
          ],
        },
      },
    },
    {
      name: 'machine-api-operator',
      config: smDefaults('openshift-machine-api', 'machine-api-operator') {
        spec+: {
          endpoints: [
            endpointDefaults {
              port: 'https',
              tlsConfig+: {
                serverName: 'machine-api-operator.openshift-machine-api.svc',
              },
            },
          ],
        },
      },
    },
  ],

  'openshift-machine-config-operator': [
    {
      name: 'machine-config-daemon',
      config: smDefaults('openshift-machine-config-operator', 'machine-config-daemon') {
        spec+: {
          endpoints: [
            endpointDefaults {
              path: '/metrics',
              port: 'metrics',
              relabelings+: [
                {
                  action: 'replace',
                  regex: ';(.*)',
                  replacement: '$1',
                  separator: ';',
                  sourceLabels: [
                    'node',
                    '__meta_kubernetes_pod_node_name',
                  ],
                  targetLabel: 'node',
                },
              ],
              tlsConfig+: {
                serverName: 'machine-config-daemon.openshift-machine-config-operator.svc',
              },
            },
          ],
        },
      },
    },
  ],
};

local promInstance = com.getValueOrDefault(
  params.syn_monitoring,
  'instance',
  inv.parameters.prometheus.defaultInstance
);

local nsName = 'syn-monitoring-openshift4-nodes';

if syn_metrics then
  {
    namespace: prometheus.RegisterNamespace(
      kube.Namespace(nsName),
      instance=promInstance,
    ),
    // Note: we don't need network policies here, since the target namespaces
    // don't have any network policies present by default.
    serviceMonitors: [
      // ServiceMonitors in our namespace
      prometheus.ServiceMonitor('%s-%s' % [ ns, sm.name ]) {
        metadata+: {
          namespace: nsName,
        },
      } + sm.config
      for ns in namespaces
      for sm in serviceMonitors[ns]
    ],
  }
else
  std.trace(
    'Monitoring disabled or component `prometheus` not present, '
    + 'not deploying ServiceMonitors',
    {}
  )
