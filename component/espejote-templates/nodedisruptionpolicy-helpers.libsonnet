// get node disruption policy from machineconfig annotation
local get_disruption_config(mc) =
  local annotation_key = 'openshift4-nodes.syn.tools/node-disruption-policies';
  local annotations = std.get(mc.metadata, 'annotations', {});
  std.parseJson(std.get(annotations, annotation_key, '{}'));

// Validate passed list of node disruption policy actions.
// Currently only validates that actions lists with > 1 entry don't contain
// `Reboot` or `None`.
local validate_actions(actions) =
  local valid =
    std.length(actions) <= 1 ||
    !(std.member(actions, { type: 'Reboot' }) || std.member(actions, { type: 'None' }));
  assert valid : 'Actions %s is invalid' % [ actions ];
  actions;

// Selects "most disruptive" list of actions from the passed list of lists.
// Reboot is treated as most disruptive, arbitrary other actions are
// concatenated (TBD if this makes sense) and None is treated as least
// disruptive.
local select_actions(actions) = validate_actions(std.foldl(
  function(curr, a)
    if std.length(a) == 0 then curr
    else if std.length(curr) == 0 then a
    else if curr[0].type == 'Reboot' then curr
    else if a[0].type == 'Reboot' then a
    else if curr[0].type == 'None' then a
    else if a[0].type == 'None' then curr
    else curr + a,
  actions,
  []
));

// Removes duplicate entries from a list of policies. Should only be used for
// `files` and `units` policy lists. For duplicate entries, the most
// disruptive action (cf. `select_actions()` is picked for the resulting
// entry.
local remove_duplicates(pols, keyField) =
  local pol_actions = std.foldl(function(res, p) res { [p[keyField]]+: [ p.actions ] }, pols, {});
  [
    {
      [keyField]: k,
      actions: select_actions(pol_actions[k]),
    }
    for k in std.objectFields(pol_actions)
  ];


{
  get_disruption_config: get_disruption_config,
  select_actions: select_actions,
  remove_duplicates: remove_duplicates,
}
