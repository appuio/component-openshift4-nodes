local com = import 'lib/commodore.libjsonnet';
local espejote = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;
local metrics = import 'autoscaling-metrics.libsonnet';

local autoscalerArgsPatch = if params.autoscaling.addAutoscalerArgs != null && std.length(params.autoscaling.addAutoscalerArgs) > 0 then
  assert std.member(inv.applications, 'espejote') : 'The addAutoscalerArgs patch depends on espejote';
  {
    autoscaler_inject_args_admission: espejote.admission('autoscaler-inject-args', params.machineApiNamespace) {
      metadata+: {
        annotations+: {
          'syn.tools/description': |||
            Injects autoscaler arguments to the default autoscaler pod in the openshift-machine-api namespace.
            Arguments are taken from the a JsonnetLibrary manifest with the same name.

            The patch blindly adds the arguments without trying to replace them if they already exist.
            I debated replacing them but we won't be able to guess all upstream changes in the args array and our args parsing might fail anyways.
            I prefer a simpler patch that fails fast to a convoluted args array merge.
          |||,
        },
      },
      spec: {
        mutating: true,
        webhookConfiguration: {
          rules: [
            {
              apiGroups: [
                '',
              ],
              apiVersions: [
                '*',
              ],
              operations: [
                'CREATE',
              ],
              resources: [
                'pods',
              ],
            },
          ],
          objectSelector: {
            matchLabels: {
              'cluster-autoscaler': 'default',
              'k8s-app': 'cluster-autoscaler',
            },
          },
        },
        template: importstr 'espejote-templates/patch-autoscaler-args.jsonnet',
      },
    },
    autoscaler_inject_args_jsonnetlibrary: espejote.jsonnetLibrary('autoscaler-inject-args', params.machineApiNamespace) {
      spec: {
        data: {
          'flags.json': std.manifestJson(params.autoscaling.addAutoscalerArgs),
        },
      },
    },
  }
else
  {};

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
] + (if params.autoscaling.ignoreDownscalingSync then [
       {
         group: 'autoscaling.openshift.io',
         kind: 'ClusterAutoscaler',
         name: 'default',
         jsonPointers: [ '/spec/scaleDown/enabled' ],
       },
     ] else []);

// Add new ServiceAccount
local autoscalerServiceAccount = kube.ServiceAccount('scheduled-downscaler') {
  metadata+: {
    namespace: params.machineApiNamespace,
  },
};

// Add new ClusterRole
local autoscalerClusterRole = kube.ClusterRole('scheduled-downscaler-role') {
  rules: [
    {
      apiGroups: [ 'autoscaling.openshift.io' ],
      resources: [ 'clusterautoscalers' ],
      verbs: [ 'get', 'patch' ],
    },
  ],
};

// Add new ClusterRoleBinding
local autoscalerClusterRoleBinding = kube.ClusterRoleBinding('scheduled-downscaler-binding') {
  roleRef: {
    apiGroup: 'rbac.authorization.k8s.io',
    kind: 'ClusterRole',
    name: 'scheduled-downscaler-role',
  },
  subjects: [
    {
      kind: 'ServiceAccount',
      name: 'scheduled-downscaler',
      namespace: params.machineApiNamespace,
    },
  ],
};

// Create base CronJob function
local scheduledDownscalerCronJob(name, schedule, timeZone, enabled) = kube.CronJob('scheduled-downscaler-' + name) {
  metadata+: {
    namespace: params.machineApiNamespace,
  },
  spec+: {
    schedule: schedule,
    timeZone: timeZone,
    jobTemplate: {
      spec: {
        template: {
          spec: {
            serviceAccountName: 'scheduled-downscaler',
            containers: [
              {
                name: 'autoscale-' + name + 'r',
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                imagePullPolicy: 'IfNotPresent',
                command: [
                  'oc',
                  'patch',
                  'clusterautoscalers',
                  'default',
                  '--type',
                  'merge',
                  '-p',
                  '{"spec":{"scaleDown":{"enabled": ' + enabled + '}}}',
                ],
                env: [
                  {
                    name: 'HOME',
                    value: '/home/downscaler',
                  },
                ],
                volumeMounts: [
                  {
                    name: 'home',
                    mountPath: '/home/downscaler',
                  },
                ],
              },
            ],
            volumes: [
              {
                name: 'home',
                emptyDir: {},
              },
            ],
            restartPolicy: 'Never',
          },
        },
      },
    },
  },
};

// Create the enable and disable jobs using the base function
local enableDownscalerCronJob = scheduledDownscalerCronJob('enable', params.autoscaling.schedule.enableExpression, params.autoscaling.schedule.timeZone, true);
local disableDownscalerCronJob = scheduledDownscalerCronJob('disable', params.autoscaling.schedule.disableExpression, params.autoscaling.schedule.timeZone, false);

// Deploy missing 4.19 autoscaler RBAC
local extraRBAC = [
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: {
      name: 'syn:cluster-autoscaler:volumeattachments',
    },
    rules: [
      {
        apiGroups: [
          'storage.k8s.io',
        ],
        resources: [
          'volumeattachments',
        ],
        verbs: [
          'get',
          'list',
          'watch',
        ],
      },
    ],
  },
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      name: 'syn:cluster-autoscaler:volumeattachments',
    },
    roleRef: {
      kind: 'ClusterRole',
      name: 'syn:cluster-autoscaler:volumeattachments',
    },
    subjects: [
      {
        kind: 'ServiceAccount',
        name: 'cluster-autoscaler',
        namespace: 'openshift-machine-api',
      },
    ],
  },
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
    extra_rbac: extraRBAC,
    [if std.length(machineAutoscalers) > 0 then
      'machine_autoscalers']: machineAutoscalers,
    [if priorityExpanderConfigmap != null then
      'priority_expander_configmap']: priorityExpanderConfigmap,
    [if params.autoscaling.schedule.enabled then
      'downscale_cronjobs']: [
      autoscalerServiceAccount,
      autoscalerClusterRole,
      autoscalerClusterRoleBinding,
      enableDownscalerCronJob,
      disableDownscalerCronJob,
    ],
    ignoreDifferences:: ignoreDifferences,
    [if params.autoscaling.customMetrics.enabled then
      'autoscaling_metrics_prometheusrules']: metrics,
  } + autoscalerArgsPatch
else {
  ignoreDifferences:: [],
}
