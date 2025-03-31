local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.openshift4_nodes;

local namespace = 'openshift-machine-config-operator';

local sa = kube.ServiceAccount('nodedisruptionpolicies-manager') {
  metadata+: {
    namespace: namespace,
  },
};

local cr = kube.ClusterRole('espejote:nodedisruptionpolicies') {
  rules: [
    {
      apiGroups: [ 'operator.openshift.io' ],
      resources: [ 'machineconfigurations' ],
      verbs: [ 'get', 'list', 'watch', 'update', 'patch' ],
    },
    {
      apiGroups: [ 'machineconfiguration.openshift.io' ],
      resources: [ 'machineconfigs' ],
      verbs: [ 'get', 'list', 'watch' ],
    },
  ],
};

local crb = kube.ClusterRoleBinding('espejote:nodedisruptionpolicies') {
  roleRef_: cr,
  subjects_: [ sa ],
};

local role = kube.Role('espejote:nodedisruptionpolicies') {
  metadata+: {
    namespace: namespace,
  },
  rules: [
    {
      apiGroups: [ 'espejote.io' ],
      resources: [ 'jsonnetlibraries' ],
      verbs: [ 'get', 'list', 'watch' ],
    },
  ],
};

local rb = kube.RoleBinding('espejote:nodedisruptionpolicies') {
  metadata+: {
    namespace: namespace,
  },
  roleRef_: role,
  subjects_: [ sa ],
};

local ndp = import
  'espejote-templates/nodedisruptionpolicy-helpers.libsonnet';

local jsonnetlib =
  local ndp_params = params.nodeDisruptionPolicies;
  esp.jsonnetLibrary('nodedisruptionpolicies', namespace) {
    spec: {
      data: {
        'ndp.libsonnet': importstr 'espejote-templates/nodedisruptionpolicy-helpers.libsonnet',
        'config.json': std.manifestJson({
          files: [
            {
              path: f,
              actions: ndp.select_actions([ ndp_params.files[f] ]),
            }
            for f in std.objectFields(ndp_params.files)
          ],
          units: [
            {
              name: u,
              actions: ndp.select_actions([ ndp_params.units[u] ]),
            }
            for u in std.objectFields(ndp_params.units)
          ],
          sshkey_actions: ndp.select_actions([ ndp_params.sshkey_actions ]),
        }),
      },
    },
  };

local machineconfigs = {
  apiVersion: 'machineconfiguration.openshift.io/v1',
  kind: 'MachineConfig',
  labelSelector: {
    matchExpressions: [ {
      key: 'machineconfiguration.openshift.io/role',
      operator: 'Exists',
    } ],
  },
};
local machineconfiguration_cluster = {
  apiVersion: 'operator.openshift.io/v1',
  kind: 'MachineConfiguration',
};

local jsonnetlib_ref = {
  apiVersion: jsonnetlib.apiVersion,
  kind: jsonnetlib.kind,
  name: jsonnetlib.metadata.name,
  namespace: jsonnetlib.metadata.namespace,
};

local managedresource =
  esp.managedResource('nodedisruptionpolicies', namespace) {
    metadata+: {
      annotations: {
        'syn.tools/description': |||
          Manages `spec.nodeDisruptionPolicies` in the `machineconfiguration.operator/cluster` resource.

          The contents of `spec.nodeDisruptionPolicies` are constructed from the
          annotation `openshift4-nodes.syn.tools/node-disruption-policies` on all
          non-generated MachineConfigs. We generally recommend defining very
          specific paths for `files` disruption policies in order to avoid
          confilicting configurations in the resulting merged config.

          Any unmanaged contents of `spec.nodeDisruptionPolicies` are overwritten.
          We explicitly execute the template when the
          `machineconfiguration.operator/cluster` resource changes.

          Generic disruption policies which are provided via Project Syn
          parameter are provided in field `config.json` in the
          `nodedisruptionpolicies` Espejote JsonnetLibrary resource.

          NOTE: Don't configure `type: Restart` for systemd units that are managed
          in the machineconfig resource. Doing so will cause nodes to become
          degraded if the machineconfig is deleted.

          NOTE: In general, we can't guarantee that node disruption policies
          provided in an annotation will still be active when the machineconfig
          is deleted. If you want to guarantee that removing a machineconfig
          doesn't unnecessesarily reboots machines, we recommend defining
          appropriate node disruption policies via the Project Syn hierarchy.
        |||,
      },
    },
    spec: {
      serviceAccountRef: { name: sa.metadata.name },
      applyOptions: { force: true },
      context: [
        {
          name: 'machineconfigs',
          resource: machineconfigs,
        },
      ],
      triggers: [
        {
          name: 'machineconfig',
          watchContextResource: {
            name: 'machineconfigs',
          },
        },
        {
          name: 'machineconfiguration/cluster',
          watchResource: machineconfiguration_cluster,
        },
        {
          name: 'jsonnetlib',
          watchResource: jsonnetlib_ref,
        },
      ],
      template: importstr 'espejote-templates/nodedisruptionpolicies-template.jsonnet',
    },
  };

local ocpMinor = std.parseInt(params.openshiftVersion.Minor);

if ocpMinor >= 17 && std.member(inv.applications, 'espejote') then
  {
    nodedisruptionpolicies_rbac: [ sa, cr, crb, role, rb ],
    nodedisruptionpolicies_managedresource: [ jsonnetlib, managedresource ],
  }
else
  local reason = if ocpMinor >= 17 then
    'Espejote not installed'
  else
    'Node disruption policies not available on OpenShift 4.%d' % ocpMinor;
  std.trace(
    'Skipping configuration of node disruption policy management: %s.' % reason,
    {}
  )
