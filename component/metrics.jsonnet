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

local endpointDefaults = {
  metricRelabelings: [
    prometheus.DropRuntimeMetrics,
  ],
};

local smDefaults(ns, name) = {
  targetNamespace: ns,
  selector: {
    matchLabels: {
      'k8s-app': name,
    },
  },
};

local serviceMonitors = {
  'openshift-machine-api': [
    prometheus.ServiceMonitor('cluster-autoscaler-operator') +
    smDefaults('openshift-machine-api', 'cluster-autoscaler-operator') {
      endpoints: {
        operator: prometheus.ServiceMonitorHttpsEndpoint(
          'cluster-autoscaler-operator.openshift-machine-api.svc'
        ) + endpointDefaults,
      },
    },
    prometheus.ServiceMonitor('machine-api-controllers') +
    smDefaults('openshift-machine-api', 'controller') {
      endpoints: {
        machine_mtrc:
          prometheus.ServiceMonitorHttpsEndpoint(
            'machine-api-controllers.openshift-machine-api.svc'
          ) + endpointDefaults {
            port: 'machine-mtrc',
          },
        machineset_mtrc:
          prometheus.ServiceMonitorHttpsEndpoint(
            'machine-api-controllers.openshift-machine-api.svc'
          ) + endpointDefaults {
            port: 'machineset-mtrc',
          },
        mhc_mtrc:
          prometheus.ServiceMonitorHttpsEndpoint(
            'machine-api-controllers.openshift-machine-api.svc'
          ) + endpointDefaults {
            port: 'mhc-mtrc',
          },
      },
    },
    prometheus.ServiceMonitor('machine-api-operator') +
    smDefaults('openshift-machine-api', 'machine-api-operator') {
      endpoints: {
        operator:
          prometheus.ServiceMonitorHttpsEndpoint(
            'machine-api-operator.openshift-machine-api.svc',
          ) + endpointDefaults {
            port: 'https',
          },
      },
    },
  ],

  'openshift-machine-config-operator': [
    prometheus.ServiceMonitor('machine-config-daemon') +
    smDefaults('openshift-machine-config-operator', 'machine-config-daemon') {
      endpoints: {
        mcd:
          prometheus.ServiceMonitorHttpsEndpoint(
            'machine-config-daemon.openshift-machine-config-operator.svc'
          ) + endpointDefaults {
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
          },
      },
    },
  ],
};

local promInstance =
  if params.monitoring.instance != null then
    params.monitoring.instance
  else
    inv.parameters.prometheus.defaultInstance;

local nsName = 'syn-monitoring-openshift4-nodes';

if syn_metrics then
  {
    namespace: prometheus.RegisterNamespace(
      kube.Namespace(nsName),
      instance=promInstance,
    ),
    // Note: we don't need network policies here, since the target namespaces
    // don't have any network policies present by default.
    serviceMonitors: std.filter(
      function(it) it != null,
      [
        if params.monitoring.enableServiceMonitors[sm.metadata.name] then
          sm {
            metadata+: {
              name: '%s-%s' % [ sm.targetNamespace, sm.metadata.name ],
              namespace: nsName,
            },
          }
        for ns in namespaces
        for sm in serviceMonitors[ns]
      ]
    ),
  }
else
  std.trace(
    'Monitoring disabled or component `prometheus` not present, '
    + 'not deploying ServiceMonitors',
    {}
  )
