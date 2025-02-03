local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local namespace = {
  metadata+: {
    namespace: 'openshift-machine-config-operator',
  },
};

local pruningRBAC =
  local sa = kube.ServiceAccount('appuio-machineconfig-pruner') + namespace;
  local cluster_role = kube.ClusterRole('appuio:machineconfig-pruner') {
    rules: [
      {
        apiGroups: [ 'machineconfiguration.openshift.io' ],
        resources: [ 'machineconfigs' ],
        verbs: [ 'get', 'list', 'delete' ],
      },
      {
        apiGroups: [ 'machineconfiguration.openshift.io' ],
        resources: [ 'machineconfigpools' ],
        verbs: [ 'get', 'list' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'nodes' ],
        verbs: [ 'get', 'list' ],
      },
    ],
  };
  local cluster_role_binding =
    kube.ClusterRoleBinding('appuio:machineconfig-pruner') {
      subjects_: [ sa ],
      roleRef_: cluster_role,
    };
  {
    sa: sa,
    cluster_role: cluster_role,
    cluster_role_binding: cluster_role_binding,
  };


local pruneScript = kube.ConfigMap('appuio-prune-machineconfigs') + namespace {
  data: {
    'machineconfig_pruning.sh': (importstr 'scripts/machineconfig_pruning.sh'),
  },
};

local pruneCronJob = kube.CronJob('appuio-prune-machineconfigs') + namespace {
  spec+: {
    failedJobsHistoryLimit: 3,
    // Wednesdays at 11:00
    schedule: '0 11 * * 3',
    timeZone: 'Europe/Zurich',
    jobTemplate+: {
      spec+: {
        template+: {
          spec+: {
            containers_+: {
              pruner: kube.Container('prune-machineconfigs') {
                image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oc,
                workingDir: '/export',
                command: [ '/scripts/machineconfig_pruning.sh' ],
                env_+: {
                  HOME: '/export',
                },
                volumeMounts_+: {
                  export: {
                    mountPath: '/export',
                  },
                  scripts: {
                    mountPath: '/scripts',
                  },
                },
              },
            },
            volumes_+: {
              export: {
                emptyDir: {},
              },
              scripts: {
                configMap: {
                  name: 'appuio-prune-machineconfigs',
                  defaultMode: std.parseOctal('0550'),
                },
              },
            },
            serviceAccountName: pruningRBAC.sa.metadata.name,
          },
        },
      },
    },
  },
};
{
  machineconfig_pruning: [ pruneScript, pruneCronJob ] + std.objectValues(pruningRBAC),
}
