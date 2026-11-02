#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')

const signInFunctions = ['supportsSignIn', 'needsSignIn', 'usageNote'].map(name => {
  const match = panelSource.match(new RegExp('function ' + name + '\\([^]*?\\n  \\}'))
  return match ? match[0] : ''
}).join('\n')
const signIn = new Function('addProviders', 'helpDisplayText', 'statusDisplayText', signInFunctions + '\nreturn {needsSignIn, usageNote}')(
  [{providerId: 'claude'}, {providerId: 'codex'}, {providerId: 'grok'}], text => text, status => status
)
for (const id of ['claude', 'codex', 'grok']) {
  assert(signIn.needsSignIn({providerId: id, usageStatusText: 'Sign-in expired'}), id + ' keeps its sign-in link')
  assertEqual(signIn.usageNote({providerId: id, usageStatusText: 'Sign-in expired'}), '', id + ' offers its sign-in link instead of a note')
}
assert(signIn.needsSignIn({usageStatusText: 'Sign-in expired'}), 'account rows keep their sign-in link')
for (const status of ['Sign-in expired', 'Waiting for auth']) {
  assert(!signIn.needsSignIn({providerId: 'agy', usageStatusText: status}), 'an agent the panel cannot sign in gets no link for ' + status)
  assertEqual(signIn.usageNote({providerId: 'agy', usageStatusText: status}), status, 'an agent the panel cannot sign in still notes ' + status)
}
assertEqual(signIn.usageNote({providerId: 'grok', usageStatusText: 'Limits paused', authHelpText: 'Start Grok to refresh it.'}),
  'Start Grok to refresh it.', 'paused limits stay on show with a note saying how to refresh them')
assertEqual(signIn.usageNote({providerId: 'grok', usageStatusText: ''}), '', 'current limits carry no note')
assertEqual(signIn.usageNote({providerId: 'grok', usageStatusText: '', limitsStale: true, authHelpText: "Couldn't reach Grok's usage endpoint."}),
  "Couldn't reach Grok's usage endpoint.", 'a failed refresh that kept its limits still says why')
assertEqual(signIn.usageNote({usageStatusText: '', stale: true, authHelpText: 'Endpoint returned 500.'}),
  'Endpoint returned 500.', 'an account whose refresh failed still says why')

// Local history alone feeds the summary; a section needs a subscription to show.
const mainSource = fs.readFileSync(root + '/shell/plugins/agents/Main.qml', 'utf8')
const subscribed = new Function(mainSource.match(/function providerHasSubscription\([^]*?\n  \}/)[0] + '\nreturn providerHasSubscription')()
const historyOnly = { limits: [], accounts: [], balance: null, tierLabel: '', totalPrompts: 1 }
assertEqual(subscribed(historyOnly), false, 'an agent with only local history gets no section')
assertEqual(subscribed({ ...historyOnly, tierLabel: 'X Premium+' }), true, 'a plan earns a section before its limits arrive')
assertEqual(subscribed({ ...historyOnly, limits: [{ label: 'Weekly', percent: 0.04 }] }), true, 'kept limits earn a section')

// A reworded collector line would silently fall back to English, so every
// fixed help line the collectors cache must still be one the panel maps.
for (const name of ['claude', 'codex', 'grok', 'fireworks']) {
  const collector = fs.readFileSync(root + '/bin/omarchy-agent-usage-' + name, 'utf8')
  const help = collector.match(/^AUTH_HELP = "([^"]+)"$/m)
  assert(help && panelSource.includes('case ' + JSON.stringify(help[1]) + ':'), name + ' auth help is translated in the panel')
}
JS

# The settings list writes the whole bar entry back, so the settings that
# were already in it have to survive the write.
run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const saveSource = panelSource.match(/function saveProviderEnabled\([^]*?\n  \}/)[0]

const written = []
const fakeRoot = {
  moduleName: 'omarchy.agents',
  settings: { refreshIntervalSec: 300, providers: { codex: { enabled: true } } },
  bar: { shell: { updateEntryInline: (id, entry) => written.push([id, entry]) } }
}
const save = new Function('root', saveSource + '\nreturn saveProviderEnabled')(fakeRoot)

save('claude', false)
assertEqual(written.length, 1, 'the toggle writes the entry once')
assertEqual(written[0][0], 'omarchy.agents', 'the entry is the widget own')
assertEqual(written[0][1].refreshIntervalSec, 300, 'the settings already in the entry survive the write')
assertEqual(written[0][1].providers.codex.enabled, true, 'the other agents keep their state')
assertEqual(written[0][1].providers.claude.enabled, false, 'the toggled agent is written')

fakeRoot.settings = {}
written.length = 0
save('claude', true)
assertEqual(written[0][1].providers.claude.enabled, true, 'a first write still lands')

fakeRoot.settings = { refreshIntervalSec: 300, providers: { codex: { enabled: true } } }
written.length = 0
save('claude', false, { claude: false })
save('grok', false, { claude: false, grok: false })
assertEqual(written[1][1].providers.claude.enabled, false, 'a second fast toggle keeps the first pending change')
assertEqual(written[1][1].providers.grok.enabled, false, 'the second fast toggle is written too')
JS

# The panel reads a window out of a label, and that guess cannot survive a
# model name — "Opus 5 (1M context)" parses as a one-minute window. A collector
# that states the title outright is taken at its word.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const panelRoot = { nowMs: Date.now() }
const start = source.indexOf('function windowIsLong')
const end = source.indexOf('// The window that decides')
assert(start > 0 && end > start, 'agents panel exposes its limit-window helpers')
eval(source.slice(start, end).replaceAll('root.nowMs', 'panelRoot.nowMs'))

assertDeepEqual(
  limitWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.78, resetsAt: '' },
    { label: 'Opus 5 (1M context) Weekly', title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.78, resetAt: '' },
    { title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetAt: '' }
  ],
  'agents panel titles a limit off the collector when it states one'
)

assertDeepEqual(
  limitWindows({ limits: [{ label: 'Weekly (7-day)', percent: 0.12, resetsAt: '' }] }),
  [{ title: 'Weekly', percent: 0.12, resetAt: '' }],
  'agents panel still reads a window out of a label that carries no title'
)

const resetAt = new Date(panelRoot.nowMs + 1000).toISOString()
const measured = { limits: [{ label: 'Session (5-hour)', percent: 0.78, resetsAt: resetAt }] }
assertEqual(limitWindows(measured)[0].percent, 0.78, 'usage remains until the reset time')
panelRoot.nowMs += 1000
assertDeepEqual(limitWindows(measured), [{ title: 'Session', percent: 0, resetAt: '' }], 'usage resets at the deadline while the panel stays open')
assertEqual(measured.limits[0].percent, 0.78, 'display reset leaves the measured record intact')

// A model's weekly allowance rides under the Weekly row; one whose window has
// no row of its own keeps a row.
assertDeepEqual(
  displayWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.94, resetsAt: '' },
    { label: 'Weekly (7-day)', percent: 0.25, resetsAt: 'w' },
    { label: 'Fable Weekly', title: 'Fable Weekly', percent: 0.09, resetsAt: 'w' },
    { label: 'Opus Monthly', title: 'Opus Monthly', percent: 0.5, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.94, resetAt: '', scoped: [] },
    { title: 'Weekly', percent: 0.25, resetAt: 'w', scoped: [{ title: 'Fable', percent: 0.09, resetAt: 'w' }] },
    { title: 'Opus Monthly', percent: 0.5, resetAt: '', scoped: [] }
  ],
  'agents panel shows a model-scoped window under the window it runs on'
)
JS

# Settings state is optimistic until the shell writes back, and ordering includes hidden agents.
run_node_test <<'JS'
const fs = require('fs')
const mainSource = fs.readFileSync(root + '/shell/plugins/agents/Main.qml', 'utf8')
const providerEnabledSource = mainSource.match(/function providerEnabled\([^]*?\n  \}/)[0]
const setProviderEnabledSource = mainSource.match(/function setProviderEnabled\([^]*?\n  \}/)[0]
const signals = []
const toggleRoot = {
  providerToggles: {},
  settings: { providers: { off: { enabled: false } } },
  providerEnabledChanged: (id, enabled) => signals.push([id, enabled])
}
const toggles = new Function('root', 'var settings = root.settings;\n' + providerEnabledSource + '\n' + setProviderEnabledSource + '\nreturn {providerEnabled, setProviderEnabled}')(toggleRoot)
assertEqual(toggles.providerEnabled('off'), false, 'a saved disabled provider starts hidden')
assertEqual(toggles.providerEnabled('new'), true, 'an unset provider starts enabled')
toggles.setProviderEnabled('off', true)
assertEqual(toggles.providerEnabled('off'), true, 'a changed switch updates immediately')
toggles.setProviderEnabled('new', false)
assertEqual(toggles.providerEnabled('new'), false, 'a new switch updates immediately')
assertDeepEqual(signals, [['off', true], ['new', false]], 'switch changes reach the save handler')

const moveSource = mainSource.match(/function moveKnownProvider\([^]*?\n  \}/)[0]
function mover(root) {
  return new Function('root',
    'var knownProviders = root.knownProviders; var providerOrder = root.providerOrder; var orderFile = root.orderFile;\n' +
    moveSource + '\nreturn function(id, to) { moveKnownProvider(id, to); root.providerOrder = providerOrder }'
  )(root)
}
function orderState(ids) {
  const writes = []
  const root = {
    knownProviders: ids.map(providerId => ({ providerId })),
    providerOrder: [],
    orderFile: { setText: text => writes.push(text) }
  }
  return { root, writes, move: mover(root) }
}

const hidden = orderState(['first', 'hidden', 'last'])
hidden.move('hidden', 0)
assertDeepEqual(hidden.root.providerOrder, ['hidden', 'first', 'last'], 'a hidden provider keeps its order slot')
assertDeepEqual(JSON.parse(hidden.writes[0]), hidden.root.providerOrder, 'the new order is persisted as provider IDs')

const clamped = orderState(['first', 'hidden', 'last'])
clamped.move('last', -1)
assertDeepEqual(clamped.root.providerOrder, ['last', 'first', 'hidden'], 'out-of-range destinations clamp to the list')
assertDeepEqual(JSON.parse(clamped.writes[0]), clamped.root.providerOrder, 'the clamped order is persisted')

const unknown = orderState(['first', 'hidden', 'last'])
unknown.move('missing', 1)
assertEqual(unknown.writes.length, 0, 'unknown providers do not write')

const unchanged = orderState(['hidden', 'first', 'last'])
unchanged.root.providerOrder = ['hidden', 'first', 'last']
unchanged.move('hidden', 0)
assertEqual(unchanged.writes.length, 0, 'an unchanged move does not write')

const syncedSource = mainSource.match(/readonly property var knownProviders:\s*\{([^]*?)\n  \}/)[1]
function knownProvidersFor(root) {
  return new Function('root', `
    var dataRevision = root.dataRevision
    var syncRevision = root.syncRevision
    var agents = root.agents
    var settings = root.settings
    var aggregateData = root.aggregateData
    var syncConfigured = function() { return root.syncEnabled }
    var orderedProviders = function(list) {
      var order = root.providerOrder
      var rank = function(p) { var i = order.indexOf(p.providerId); return i < 0 ? order.length : i }
      return list.slice().sort(function(a, b) { return rank(a) - rank(b) })
    }
    return (function() { ${syncedSource} })()
  `)(root)
}
const providersRoot = {
  dataRevision: 1,
  syncRevision: 1,
  agents: [{ record: { id: 'local', name: 'Local' } }],
  settings: { providers: { local: { enabled: false }, configured: { enabled: false } } },
  aggregateData: { providers: { local: { providerName: 'Wrong duplicate' }, synced: { providerName: 'Synced name' } } },
  syncEnabled: true,
  providerOrder: []
}
assertDeepEqual(
  knownProvidersFor(providersRoot).map(p => [p.providerId, p.providerName]),
  [['local', 'Local'], ['synced', 'Synced name'], ['configured', 'configured']],
  'settings includes local, synced-only, and saved providers without duplicates'
)
providersRoot.syncEnabled = false
assertDeepEqual(
  knownProvidersFor(providersRoot).map(p => p.providerId),
  ['local', 'configured'],
  'unconfigured synced providers stay out of the settings list'
)
JS
