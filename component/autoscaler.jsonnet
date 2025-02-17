local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;
local metrics = import 'autoscaling-metrics.libsonnet';

local priorityExpanderConfigmap =
  if std.length(params.autoscaling.priorityExpanderConfig) > 0 then
    kube.ConfigMap('cluster-autoscaler-priority-expander') {
      metadata+: {
        namespace: params.machineApiNamespace,
      },
      data: {
        priorities: std.manifestYamlDoc(params.autoscaling.priorityExpanderConfig),
      },
    };

local clusterAutoscaler =
  kube._Object(
    'autoscaling.openshift.io/v1',
    'ClusterAutoscaler',
    'default'
  ) {
    spec: {
      podPriorityThreshold: -10,
      resourceLimits: {
        maxNodesTotal: 24,
        cores: {
          min: 8,
          max: 128,
        },
        memory: {
          min: 4,
          max: 256,
        },
      },
      logVerbosity: 1,
      scaleDown: {
        enabled: true,
        delayAfterAdd: '10m',
        delayAfterDelete: '5m',
        delayAfterFailure: '30s',
        unneededTime: '5m',
        utilizationThreshold: '0.4',
      },
      expanders:
        if priorityExpanderConfigmap != null then
          // default to priority expander if priority expander config is
          // provided
          [ 'Priority' ]
        else
          [ 'Random' ],
    } + com.makeMergeable(params.autoscaling.clusterAutoscaler),
  } +
  {
    spec+: {
      // render expanders array, so that users can remove the default
      // expander by providing it prefixed with ~
      expanders: com.renderArray(super.expanders),
    },
  };

local machineAutoscaler(machineSet) =
  local missingKeys = std.setDiff(
    std.set([ 'minReplicas', 'maxReplicas' ]),
    std.set(std.objectFields(
      params.autoscaling.machineAutoscalers[machineSet]
    )),
  );
  local extraKeys = std.setDiff(
    std.set(std.objectFields(
      params.autoscaling.machineAutoscalers[machineSet]
    )),
    std.set([ 'minReplicas', 'maxReplicas' ]),
  );

  local allMachinesets =
    std.objectFields(params.nodeGroups) +
    std.objectFields(params.machineSets);
  if !std.member(allMachinesets, machineSet) then
    error "Can't create MachineAutoscaler for non-existent machine set %s" % machineSet
  else
    kube._Object(
      'autoscaling.openshift.io/v1beta1',
      'MachineAutoscaler',
      machineSet
    ) {
      metadata+: {
        namespace: params.machineApiNamespace,
      },
      spec: if std.length(missingKeys) > 0 then
        error 'MachineAutoscaler %s is missing keys %s' % [
          machineSet,
          missingKeys,
        ]
      else
        if std.length(extraKeys) > 0 then
          error 'MachineAutoscaler %s has unknown extra keys %s' % [
            machineSet,
            extraKeys,
          ]
        else
          params.autoscaling.machineAutoscalers[machineSet] {
            scaleTargetRef: {
              apiVersion: 'machine.openshift.io/v1beta1',
              kind: 'MachineSet',
              name: machineSet,
            },
          },
    };

local machineAutoscalers = com.generateResources(
  params.autoscaling.machineAutoscalers,
  function(machineset) machineAutoscaler(machineset) {
    // hide input fields that aren't suitable for the output
    minReplicas:: 0,
    maxReplicas:: 0,
  }
);

local ignoreDifferences = [
  {
    group: 'machine.openshift.io',
    kind: 'MachineSet',
    name: ma.spec.scaleTargetRef.name,
    jsonPointers: [ '/spec/replicas' ],
  }
  for ma in machineAutoscalers
];

if params.autoscaling.enabled then
  {
    cluster_autoscaler:
      if
        std.length(params.autoscaling.machineAutoscalers) == 0 then
        std.trace(
          "WARNING: Enabling autoscaling without any MachineAutoscalers won't scale the cluster",
          clusterAutoscaler
        )
      else
        clusterAutoscaler,
    [if std.length(machineAutoscalers) > 0 then
      'machine_autoscalers']: machineAutoscalers,
    [if priorityExpanderConfigmap != null then
      'priority_expander_configmap']: priorityExpanderConfigmap,
    ignoreDifferences:: ignoreDifferences,
    [if params.autoscaling.metrics.enabled then
      'autoscaling_metrics_prometheusrules']: metrics,
  }
else {
  ignoreDifferences:: [],
}
