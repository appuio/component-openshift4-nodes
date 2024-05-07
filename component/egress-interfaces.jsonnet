local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.openshift4_nodes;

local script = (importstr 'scripts/create-egress-interfaces.sh') % {
  kubelet_kubeconfig: params.egressInterfaces.nodeKubeconfig,
  cm_namespace: params.egressInterfaces.shadowRangeConfigMap.namespace,
  cm_name: params.egressInterfaces.shadowRangeConfigMap.name,
};

local configs = [
  common.MachineConfig(
    '%s-egress-interfaces' %
    poolname
  ) {
    metadata+: {
      annotations+: {
        'inline-contents.machineconfig.syn.tools/create-egress-interfaces.sh': script,
      },
      labels+: {
        'machineconfiguration.openshift.io/role': poolname,
      },
    },
    spec+: {
      config: {
        ignition: {
          version: '3.4.0',
        },
        storage: {
          files: [
            {
              path: '/usr/local/bin/appuio-create-egress-interfaces.sh',
              mode: std.parseOctal('0755'),
              contents: {
                source:
                  'data:text/plain;charset=utf-8;base64,%s' %
                  std.base64(script),
              },
            },
          ],
        },
        systemd: {
          units: [
            {
              name: 'appuio-create-egress-interfaces.service',
              enabled: true,
              contents: |||
                [Unit]
                Description=Assign egress IPs to node interface
                After=NetworkManager-wait-online.service
                Before=kubelet-dependencies.target
                [Service]
                ExecStart=/usr/local/bin/appuio-create-egress-interfaces.sh
                Type=oneshot
                [Install]
                WantedBy=kubelet-dependencies.target
              |||,
            },
          ],
        },
      },
    },
  }
  for poolname in com.renderArray(params.egressInterfaces.machineConfigPools)
];

{
  [if std.length(configs) > 0 then '30_egress_interfaces']: configs,
}
