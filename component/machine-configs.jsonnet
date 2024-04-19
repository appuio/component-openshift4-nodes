local common = import 'common.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local machineConfigPools = import 'machine-config-pools.libsonnet';

local params = inv.parameters.openshift4_nodes;

local mergedConfigs = machineConfigPools.MachineConfigs + com.makeMergeable(params.machineConfigs);

local machineConfigs = [
  if std.objectHas(mc.spec.config, 'storage') &&
     std.objectHas(mc.spec.config.storage, 'files') then
    local inline_files = std.filter(
      function(f) std.objectHas(f.contents, 'inline'),
      mc.spec.config.storage.files
    );
    mc {
      metadata+: {
        annotations+: {
          [
          // generate a valid annotation key. Maximum length of the key name (after the /) is 63, cf.
          // https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/#syntax-and-character-set
          local fname =
            // annotation keys only support characters `[a-zA-Z0-9_-]`, so we
            // drop the first `/` and transform all remaining `/` in the path
            // to `-`.
            local sanitized = std.strReplace(
              std.lstripChars(f.path, '/'), '/', '-'
            );
            // if the file path is too long, we remove the first section,
            // since there's a lower chance that two suffices collide than
            // two prefixes. In most cases, we won't be managing files with a
            // >63 character path anyway.
            local len = std.length(sanitized);
            local start = std.max(len - 63, 0);
            std.substr(sanitized, start, len);
          'inline-contents.machineconfig.syn.tools/%s' % fname
          ]: f.contents.inline
          for f in inline_files
        },
      },
      spec+: {
        config+: {
          storage+: {
            files: [
              if std.objectHas(f.contents, 'inline') then
                f {
                  contents+: {
                    inline:: null,
                    source:
                      'data:text/plain;charset=utf-8;base64,%s' %
                      std.base64(f.contents.inline),
                  },
                }
              else
                f
              for f in super.files
            ],
          },
        },
      },
    }
  else
    mc
  for mc in com.generateResources(mergedConfigs, common.MachineConfig)
];
{
  [if std.length(machineConfigs) > 0 then '10_machineconfigs']: machineConfigs,
}
