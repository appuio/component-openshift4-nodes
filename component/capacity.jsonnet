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

local _surroundWithRelabel(metric, relabelObj) =
  'label_replace(%(metric)s, "%(targetLabel)s", "%(targetValue)s", "%(sourceLabel)s", "%(sourceValue)s")' % {
    metric: metric,
    sourceLabel: relabelObj.sourceLabel,
    sourceValue: relabelObj.sourceValue,
    targetLabel: relabelObj.targetLabel,
    targetValue: relabelObj.targetValue,
  };

local relabelMachineSets(metric) =
  // Changes the `machineset` label on the given metric, modifying the values as per `params.capacityAlerts.aggregateMachineSets`.
  std.foldl(
    _surroundWithRelabel,
    std.map(
      (function(it) { sourceLabel: 'machineset', sourceValue: it.value, targetLabel: 'machineset', targetValue: it.key }),
      std.objectKeysValues(params.capacityAlerts.aggregateMachineSets),
    ),
    metric
  );

local addNodeLabels(metric) =
  // Joins a metric with `kube_node_labels`, but only if node labels are actually of interest (i.e. we wish to aggregate by labels later on)
  if std.length(byLabels) > 0 then
    '%(metric)s * on(node) group_left(%(labelList)s) kube_node_labels' %
    { metric: metric, labelList: std.join(', ', byLabels) }
  else
    metric;

local addMachineSets(metric) =
  // Joins a metric with `openshift_upgrade_controller_machine_info`, taking into account any renaming/aggregating of machinesets that is desired.
  '%(metric)s * on(node) group_left(%(labelList)s) %(machinesetQuery)s' %
  {
    metric: metric,
    labelList: 'machineset',
    machinesetQuery: relabelMachineSets('label_replace(openshift_upgrade_controller_machine_info, "node", "$1", "node_ref", "(.+)")'),
  };

local renameNodeLabel(expression, nodeLabel) =
  // Surrounds the `expression` promql with a label_replace that renames the given `nodeLabel` to "node".
  // If the `nodeLabel` is already "node", return `expression` unchanged.
  if nodeLabel == 'node' then
    expression
  else
    'label_replace(%(expression)s, "node", "$1", "%(nodeLabel)s", "(.+)")' %
    { expression: expression, nodeLabel: nodeLabel };

local filterWorkerNodesByMachineSet(metric, machineSetFilter=machineSetFilter, nodeLabel='node') =
  // Given a metric that has a node label, join it with machineset information and return only those timeseries pertaining to machinesets we're interested in.
  '%(metric)s * on(node) group_left(%(labelList)s) %(machinesetQuery)s' %
  {
    metric: renameNodeLabel(metric, nodeLabel),
    labelList: 'machineset',
    machinesetQuery: relabelMachineSets('label_replace(openshift_upgrade_controller_machine_info{machineset=~"%(machineSetFilter)s"}, "node", "$1", "node_ref", "(.+)")' % { machineSetFilter: machineSetFilter }),
  };

local filterWorkerNodesByRole(metric, workerRole=nodeRoleFilter, nodeLabel='node') =
  // Given a metric that has a node label, join it with node role information and return only those timeseries pertaining to node roles we're interested in.
  addNodeLabels(
    '%(metric)s * on(node) group_left kube_node_role{role=~"%(workerRole)s"}' %
    { metric: renameNodeLabel(metric, nodeLabel), nodeLabel: nodeLabel, workerRole: workerRole }
  );

local filterWorkerNodes(metric, workerIdentifier='', nodeLabel='node') =
  // Given a metric that has a node label, filter out only those timeseries we're interested in. (e.g. specific machinesets or specific node roles)
  if useMachineSets then
    filterWorkerNodesByMachineSet(metric, (if workerIdentifier != '' then workerIdentifier else machineSetFilter), nodeLabel)
  else
    filterWorkerNodesByRole(metric, (if workerIdentifier != '' then workerIdentifier else nodeRoleFilter), nodeLabel);

local aggregate(expression, aggregator='sum') =
  // Aggregates a metric, automatically inserting `by X` expressions as configured. (e.g. sum by machineset or sum by node labels)
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
  // Given a resource metric, find the node that has the maximum of the given resource within each interesting category (e.g. per machineset or per node role)
  // Useful for capacity metrics such as "allocatable memory", to answer the question "how much allocatable memory per node do I get in this node role / machineset, assuming the nodes are all the same?"
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
  // Given a "amount of resource available on cluster" style metric, and a "resource capacity on one node" style metric, figure out how much of that resource would be free if, hypothetically, the cluster were autoscaled to maximum capacity.
  // Basic formula: "Hypothetical free resources" = "Current free resources" + ("Maximum hypothetical node count" - "current node count") * "Resource capacity on one node"
  // If direction is `min`, instead returns "how much of that resource would be free if, hypothetically, the cluster were autoscaled to minimum capacity" - this can be negative. (Useful for figuring out whether the cluster minimum size is too big.)

  // If the cluster has no autoscaling, then the original `freeResourceMetric` is returned unmodified.

  if useMachineSets then
    if hasAutoScaling then
      local currentNodeCountMetricBase = 'label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)")';
      local machinesetMaxSizeBase = 'max by(machineset) (component_openshift4_nodes_machineset_replicas_max or on(machineset) label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)"))';
      local machinesetMinSizeBase = 'min by(machineset) (component_openshift4_nodes_machineset_replicas_min or on(machineset) label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)"))';

      // NOTE(aa): When we're aggregating multiple actual machinesets together, we later on change the label values on the result of the above query. (e.g. change all machinesets `app-.*` to `app`)
      //           That leads to duplicate label sets - to avoid this, we need a version of this query that has another label which can stay unique.
      //           The below "DualLabel" variant of the above query keeps the original "name" label with the same value as "machineset". In a later aggregation this label disappears again.
      local machinesetMaxSizeDualLabel = 'max by(machineset, name) (label_replace(component_openshift4_nodes_machineset_replicas_max, "name", "$1", "machineset", "(.+)") or on(machineset, name) label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)"))';
      local machinesetMinSizeDualLabel = 'min by(machineset, name) (label_replace(component_openshift4_nodes_machineset_replicas_min, "name", "$1", "machineset", "(.+)") or on(machineset, name) label_replace(mapi_machine_set_status_replicas_available, "machineset", "$1", "name", "(.+)"))';

      // If we're trying to aggregate multiple actual machinesets, sum up their maxima/minima - otherwise return the base query.
      local machinesetMaxSizeAggregated = if std.length(params.capacityAlerts.aggregateMachineSets) == 0 then machinesetMaxSizeBase else ('sum by (machineset) (%(relabeled)s)' % { relabeled: relabelMachineSets(machinesetMaxSizeDualLabel) });
      local machinesetMinSizeAggregated = if std.length(params.capacityAlerts.aggregateMachineSets) == 0 then machinesetMinSizeBase else ('sum by (machineset) (%(relabeled)s)' % { relabeled: relabelMachineSets(machinesetMinSizeDualLabel) });
      local currentNodeCountMetricAggregated = if std.length(params.capacityAlerts.aggregateMachineSets) == 0 then currentNodeCountMetricBase else 'sum by (machineset) (%(relabeled)s)' % { relabeled: relabelMachineSets(currentNodeCountMetricBase) };

      // Return combined formula
      '%(metric)s + on(machineset) (%(minOrMax)s - on(machineset) %(currentNodeCount)s) * on(machineset) %(capacityPerNode)s' %
      { metric: freeResourceMetric, nodeLabel: nodeLabel, minOrMax: if direction == 'max' then machinesetMaxSizeAggregated else machinesetMinSizeAggregated, currentNodeCount: currentNodeCountMetricAggregated, capacityPerNode: capacityPerNode }
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
      labels+: {
        'espejote.io/ignore': '',
      },
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
