local esp = import 'espejote.libsonnet';
local admission = esp.ALPHA.admission;

local flagsToAdd = import 'autoscaler-inject-args/flags.json';

local pod = admission.admissionRequest().object;

local cids = std.find('cluster-autoscaler', std.map(function(c) c.name, pod.spec.containers));
assert std.length(cids) == 1 : "Expected to find a single container with name 'cluster-autoscaler'";
local containerIndex = cids[0];

// Asserts against null.
// We could just add an empty array as args before the patch and don't fail but it might be better for someone to check what changed.
local args = std.get(pod.spec.containers[containerIndex], 'args');
assert std.isArray(args) : 'Expected container args to be an array, is: %s' % std.type(args);

local containerPath = '/spec/containers/%s' % containerIndex;
admission.patched('added autoscaler args', admission.assertPatch(std.map(
  function(f) admission.jsonPatchOp('add', containerPath + '/args/-', f),
  flagsToAdd,
)))
