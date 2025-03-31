local esp = import 'espejote.libsonnet';
local defaultAnnotations = import 'service-loadbalancer-default-annotations/annotations.json';

local lbServices = std.filter(
  function(s) std.get(s.spec, 'type') == 'LoadBalancer',
  esp.context().services
);

local defaultedAnnotationsForService = function(s) {
  [if !std.objectHas(std.get(s.metadata, 'annotations', {}), k) then k]: defaultAnnotations[k]
  for k in std.objectFields(defaultAnnotations)
};

local annotationPatchForService = function(s) {
  apiVersion: s.apiVersion,
  kind: s.kind,
  metadata: {
    name: s.metadata.name,
    namespace: s.metadata.namespace,
    annotations: defaultedAnnotationsForService(s),
  },
};

std.filter(
  function(p) p.metadata.annotations != {},
  std.map(
    annotationPatchForService,
    lbServices,
  ),
)
