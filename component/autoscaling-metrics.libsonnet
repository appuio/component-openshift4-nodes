local monitoringOperator = import 'cluster-monitoring-operator/main.jsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local prom = import 'lib/prom.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;
local metrics = params.metrics;

local ruleNameMax = 'component_openshift4_nodes_machineset_replicas_max';
local ruleNameMin = 'component_openshift4_nodes_machineset_replicas_min';

local rulesFromMachineSet(name) = [
  {
    record: ruleNameMin,
    expr: 'vector(%(minReplicas)s)' % params.autoscaling.machineAutoscalers[name],
    labels: params.autoscaling.customMetrics.extraLabels {
      machineset: name,
    },
  },
  {
    record: ruleNameMax,
    expr: 'vector(%(maxReplicas)s)' % params.autoscaling.machineAutoscalers[name],
    labels: params.autoscaling.customMetrics.extraLabels {
      machineset: name,
    },
  },
];

local allRules = std.flatMap(rulesFromMachineSet, std.objectFields(params.autoscaling.machineAutoscalers));


prom.PrometheusRule('autoscaling-metrics') {
  metadata+: {
    namespace: inv.parameters.openshift4_monitoring.namespace,
  },
  spec+: {
    groups: [
      {
        name: 'component-openshift4-nodes-autoscaling-prometheusrules',
        rules: allRules,
      },
    ],
  },
}
