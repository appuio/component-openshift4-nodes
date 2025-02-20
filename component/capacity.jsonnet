local monitoringOperator = import 'cluster-monitoring-operator/main.jsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local prom = import 'lib/prom.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;
local customAnnotations = params.capacityAlerts.customAnnotations;
local machineSetFilter = '(%s)' % std.join('|', com.renderArray(params.capacityAlerts.monitorMachineSets));
local nodeRoleFilter = '(%s)' % std.join('|', com.renderArray(params.capacityAlerts.monitorNodeRoles));

local defaultAnnotations = {
  syn_component: inv.parameters._instance,
};

local alertLabels = {
  severity: 'warning',
  syn: 'true',
  syn_component: 'openshift4-monitoring',
  [if std.objectHas(inv.parameters, 'syn') then 'syn_team']: std.get(inv.parameters.syn, 'owner', ''),
};

local useMachineSets =
  std.length(params.nodeGroups) > 0 || std.length(params.machineSets) > 0;

local byLabels =
  [ 'role' ] + com.renderArray(params.capacityAlerts.groupByNodeLabels);

local hasAutoScaling =
  params.autoscaling.enabled;

local predict(indicator, range='1d', resolution='5m', predict='3*24*60*60') =
  'predict_linear(avg_over_time(%(indicator)s[%(range)s:%(resolution)s])[%(range)s:%(resolution)s], %(predict)s)' %
  { indicator: indicator, range: range, resolution: resolution, predict: predict };


local addNodeLabels(metric) =
  if std.length(byLabels) > 0 then
    '%(metric)s * on(node) group_left(%(labelList)s) kube_node_labels' %
    { metric: metric, labelList: std.join(', ', byLabels) }
  else
    metric;

local addMachineSets(metric) =
  '%(metric)s * on(node) group_left(%(labelList)s) label_replace(openshift_upgrade_controller_machine_info, "node", "$1", "node_ref", "(.+)")' %
  { metric: metric, labelList: 'machineset' };

local renameNodeLabel(expression, nodeLabel) =
  if nodeLabel == 'node' then
    expression
  else
    'label_replace(%(expression)s, "node", "$1", "%(nodeLabel)s", "(.+)")' %
    { expression: expression, nodeLabel: nodeLabel };

local filterWorkerNodesByMachineSet(metric, machineSetFilter=machineSetFilter, nodeLabel='node') =
  '%(metric)s * on(node) group_left(machineset) label_replace(openshift_upgrade_controller_machine_info{machineset=~"%(machineSetFilter)s"}, "node", "$1", "node_ref", "(.+)")' %
  { metric: renameNodeLabel(metric, nodeLabel), nodeLabel: nodeLabel, machineSetFilter: machineSetFilter }
;

local filterWorkerNodesByRole(metric, workerRole=nodeRoleFilter, nodeLabel='node') =
  addNodeLabels(
    '%(metric)s * on(node) group_left kube_node_role{role=~"%(workerRole)s"}' %
    { metric: renameNodeLabel(metric, nodeLabel), nodeLabel: nodeLabel, workerRole: workerRole }
  );

local filterWorkerNodes(metric, workerIdentifier='', nodeLabel='node') =
  if useMachineSets then
    filterWorkerNodesByMachineSet(metric, (if workerIdentifier != '' then workerIdentifier else machineSetFilter), nodeLabel)
  else
    filterWorkerNodesByRole(metric, (if workerIdentifier != '' then workerIdentifier else nodeRoleFilter), nodeLabel);

local aggregate(expression, aggregator='sum') =
  if useMachineSets then
    '%(aggregator)s by (machineset) (%(expression)s)' %
    { expression: expression, aggregator: aggregator }
  else
    if std.length(byLabels) > 0 then
      '%(aggregator)s by (%(labelList)s) (%(expression)s)' %
      { expression: expression, labelList: std.join(', ', byLabels), aggregator: aggregator }
    else
      '%(aggregator)s(%(expression)s)' %
      { expression: expression, aggregator: aggregator };

local maxPerNode(resource) =
  if useMachineSets then
    aggregate(addMachineSets(resource), aggregator='max')
  else
    aggregate(
      addNodeLabels(
        '(%(resource)s) * on(node) group_left kube_node_role{role=~"%(roleFilter)s"}' % { resource: resource, roleFilter: nodeRoleFilter },
      ),
      aggregator='max'
    );

local adjustForAutoScaling(freeResourceMetric, capacityPerNode, nodeLabel='node', direction='max') =
  if useMachineSets then
    if hasAutoScaling then
      local currentNodeCountMetric = 'mapi_machine_set_status_replicas_ready';
      local machinesetMaxSize = 'max by(machineset) (component_openshift4_monitoring_machineset_replicas_max or on(machineset) label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)"))';
      local machinesetMinSize = 'min by(machineset) (component_openshift4_monitoring_machineset_replicas_min or on(machineset) label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)"))';
      local currentNodeCountMetric = 'label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)")';
      '%(metric)s + on(machineset) (%(minOrMax)s - on(machineset) %(currentNodeCount)s) * on(machineset) %(capacityPerNode)s' %
      { metric: freeResourceMetric, nodeLabel: nodeLabel, minOrMax: if direction == 'max' then machinesetMaxSize else machinesetMinSize, currentNodeCount: currentNodeCountMetric, capacityPerNode: capacityPerNode }
    else
      freeResourceMetric
  else
    freeResourceMetric;

local resourceCapacity(resource) = aggregate(filterWorkerNodes('kube_node_status_capacity{resource="%s"}' % resource));
local resourceAllocatable(resource) = aggregate(filterWorkerNodes('kube_node_status_allocatable{resource="%s"}' % resource));
local resourceRequests(resource) = aggregate(filterWorkerNodes('kube_pod_resource_request{resource="%s"}' % resource));

local memoryRequestsCapacityPerNode = maxPerNode('kube_node_status_allocatable{resource="memory"}');
local memoryCapacityPerNode = maxPerNode('kube_node_status_capacity{resource="memory"}');
local memoryAllocatableAtMaxCapacity = adjustForAutoScaling(resourceAllocatable('memory'), memoryRequestsCapacityPerNode);
local memoryAllocatableAtMinCapacity = adjustForAutoScaling(resourceAllocatable('memory'), memoryRequestsCapacityPerNode, direction='min');
local memoryRequests = resourceRequests('memory');
local memoryFreeAtMaxCapacity = adjustForAutoScaling(aggregate(filterWorkerNodes('node_memory_MemAvailable_bytes', nodeLabel='instance')), memoryCapacityPerNode);
local memoryFreeAtMinCapacity = adjustForAutoScaling(aggregate(filterWorkerNodes('node_memory_MemAvailable_bytes', nodeLabel='instance')), memoryCapacityPerNode, direction='min');

local cpuRequestsCapacityPerNode = maxPerNode('kube_node_status_allocatable{resource="cpu"}');
local cpuCapacityPerNode = maxPerNode('kube_node_status_capacity{resource="cpu"}');
local cpuAllocatableAtMaxCapacity = adjustForAutoScaling(resourceAllocatable('cpu'), cpuRequestsCapacityPerNode);
local cpuAllocatableAtMinCapacity = adjustForAutoScaling(resourceAllocatable('cpu'), cpuRequestsCapacityPerNode, direction='min');
local cpuRequests = resourceRequests('cpu');
local cpuIdleAtMaxCapacity = adjustForAutoScaling(aggregate(filterWorkerNodes('rate(node_cpu_seconds_total{mode="idle"}[15m])', nodeLabel='instance')), cpuCapacityPerNode);
local cpuIdleAtMinCapacity = adjustForAutoScaling(aggregate(filterWorkerNodes('rate(node_cpu_seconds_total{mode="idle"}[15m])', nodeLabel='instance')), cpuCapacityPerNode, direction='min');

local podCapacityPerNode = maxPerNode('kube_node_status_capacity{resource="pods"}');
local podCapacityAtMaxCapacity = adjustForAutoScaling(resourceCapacity('pods'), podCapacityPerNode);
local podCapacityAtMinCapacity = adjustForAutoScaling(resourceCapacity('pods'), podCapacityPerNode, direction='min');
local podCount = aggregate(filterWorkerNodes('kubelet_running_pods'));

local getExpr = function(group, rule) params.capacityAlerts.groups[group].rules[rule].expr;
local unusedReserved = getExpr('NodesUnusedCapacity', 'ClusterHasUnusedNodes').reserved;

local exprMap = {
  TooManyPods: function(arg) '%s - %s < %f * %s' % [ podCapacityAtMaxCapacity, podCount, arg.factor, podCapacityPerNode ],
  ExpectTooManyPods: function(arg) '%s - %s < %f * %s' % [ podCapacityAtMaxCapacity, predict(podCount, range=arg.range, predict=arg.predict), arg.factor, podCapacityPerNode ],

  TooMuchMemoryRequested: function(arg) '%s - %s < %f * %s' % [ memoryAllocatableAtMaxCapacity, memoryRequests, arg.factor, memoryRequestsCapacityPerNode ],
  ExpectTooMuchMemoryRequested: function(arg) '%s - %s < %f * %s' % [ memoryAllocatableAtMaxCapacity, predict(memoryRequests, range=arg.range, predict=arg.predict), arg.factor, memoryRequestsCapacityPerNode ],
  TooMuchCPURequested: function(arg) '%s - %s < %f * %s' % [ cpuAllocatableAtMaxCapacity, cpuRequests, arg.factor, cpuRequestsCapacityPerNode ],
  ExpectTooMuchCPURequested: function(arg) '%s - %s < %f * %s' % [ cpuAllocatableAtMaxCapacity, predict(cpuRequests, range=arg.range, predict=arg.predict), arg.factor, cpuRequestsCapacityPerNode ],

  ClusterLowOnMemory: function(arg) '%s < %f * %s' % [ memoryFreeAtMaxCapacity, arg.factor, memoryCapacityPerNode ],
  ExpectClusterLowOnMemory: function(arg) '%s < %f * %s' % [ predict(memoryFreeAtMaxCapacity, range=arg.range, predict=arg.predict), arg.factor, memoryCapacityPerNode ],

  ClusterCpuUsageHigh: function(arg) '%s < %f * %s' % [ cpuIdleAtMaxCapacity, arg.factor, cpuCapacityPerNode ],
  ExpectClusterCpuUsageHigh: function(arg) '%s < %f * %s' % [ predict(cpuIdleAtMaxCapacity, range=arg.range, predict=arg.predict), arg.factor, cpuCapacityPerNode ],

  ClusterHasUnusedNodes: function(arg)
    '%s > %f' % [
      aggregate(
        |||
          (
            label_replace(
              (%s - %s) / %s
            , "resource", "pods", "", "")
          ) or (
            label_replace(
              (%s - %s) / %s
            , "resource", "requested_memory", "", "")
          ) or (
            label_replace(
              (%s - %s) / %s
            , "resource", "requested_cpu", "", "")
          ) or (
            label_replace(
              %s / %s
            , "resource", "memory", "", "")
          ) or (
            label_replace(
              %s / %s
            , "resource", "cpu", "", "")
          )
        ||| %
        [
          podCapacityAtMinCapacity,
          podCount,
          podCapacityPerNode,

          memoryAllocatableAtMinCapacity,
          memoryRequests,
          memoryRequestsCapacityPerNode,

          cpuAllocatableAtMinCapacity,
          cpuRequests,
          cpuRequestsCapacityPerNode,

          memoryFreeAtMinCapacity,
          memoryCapacityPerNode,

          cpuIdleAtMinCapacity,
          cpuCapacityPerNode,
        ],

        'min'
      ),
      unusedReserved,
    ],
};

{
  [if params.capacityAlerts.enabled then 'capacity_alerting_rules']: prom.PrometheusRule('openshift4-nodes-capacity') {
    metadata+: {
      annotations+: defaultAnnotations,
      namespace: inv.parameters.openshift4_monitoring.namespace,
    },
    spec+: {
      groups: std.filter(function(x) std.length(x.rules) > 0, [
        {
          local group = params.capacityAlerts.groups[alertGroupName],
          name: 'syn-' + alertGroupName,
          rules: [
            group.rules[ruleName] {
              alert: 'SYN_' + ruleName,
              enabled:: true,
              labels: alertLabels + super.labels,
              annotations: defaultAnnotations + super.annotations,
              expr:
                if std.objectHas(super.expr, 'raw') then
                  super.expr.raw
                else
                  exprMap[ruleName](super.expr),
            }
            for ruleName in std.objectFields(group.rules)
            if group.rules[ruleName].enabled
          ],
        }
        for alertGroupName in std.objectFields(params.capacityAlerts.groups)
      ]),
    },
  },
}
