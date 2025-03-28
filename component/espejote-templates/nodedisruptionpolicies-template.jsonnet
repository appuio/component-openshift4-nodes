local esp = import 'espejote.libsonnet';
local ndp = import 'nodedisruptionpolicies/ndp.libsonnet';

local config = import 'nodedisruptionpolicies/config.json';
local machineconfigs = esp.context().machineconfigs;

local render_nodedisruptionpolicies() =
  local configs = [ ndp.get_disruption_config(mc) for mc in machineconfigs ];
  local policies =
    {
      files+:
        std.get(config, 'files', []) +
        std.flattenArrays([ std.get(dc, 'files', []) for dc in configs ]),
      units+:
        std.get(config, 'units', []) +
        std.flattenArrays([ std.get(dc, 'units', []) for dc in configs ]),
      sshkey+: {
        actions:
          [ std.get(config, 'sshkey_actions', []) ] +
          [ std.get(dc, 'sshkey', { actions: [] }).actions for dc in configs ],
      },
    };
  {
    files: ndp.remove_duplicates(
      std.sort(policies.files, keyF=function(e) e.path),
      'path'
    ),
    units: ndp.remove_duplicates(
      std.sort(policies.units, keyF=function(e) e.name),
      'name'
    ),
    sshkey: { actions: ndp.select_actions(policies.sshkey.actions) },
  };

local res = {
  apiVersion: 'operator.openshift.io/v1',
  kind: 'MachineConfiguration',
  metadata: {
    name: 'cluster',
  },
  spec: {
    nodeDisruptionPolicy: render_nodedisruptionpolicies(),
  },
};

assert
  std.length(res.spec.nodeDisruptionPolicy.files) <= 50 :
  'Max supported length of nodeDisruptionPolicy.files is 50';
assert
  std.length(res.spec.nodeDisruptionPolicy.units) <= 50 :
  'Max supported length of nodeDisruptionPolicy.units is 50';

[ res ]
