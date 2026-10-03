// Skills browser and effective tools: skills.status/search/detail/install/update, tools.catalog and
// tools.effective. Mirrors openclaw src/gateway/server-methods/skills.ts, skills-status.ts,
// tools-catalog.ts, tools-effective.ts and packages/gateway-protocol/src/schema/
// agents-models-skills.ts + tools-catalog.ts:
// - scopes (src/gateway/methods/core-descriptors.ts): skills.status/search/detail and
//   tools.catalog/effective need operator.read; skills.install/update need operator.admin.
// - skills.status entries are SkillStatusEntry (src/skills/discovery/status.types.ts): eligible =
//   !disabled && !blockedByAllowlist && requirements satisfied; platformIncompatible = missing.os
//   is non-empty; modelVisible/commandVisible also need !blockedByAgentFilter.
// - skills.update has two shapes: config ({skillKey, enabled?, apiKey?, env?} → {ok, skillKey,
//   config: redacted entry}) and ClawHub ({source: "clawhub", slug | all, force?}).
// - ClawHub responses are canned: the mock host has no network. The mock platform is darwin.
// MOCK_NO_SKILLS=1 / MOCK_NO_TOOLS=1 make the mock look like a Gateway without these methods.
// MOCK_CLAWHUB_OFFLINE=1 makes ClawHub calls (search/detail/clawhub install+update) UNAVAILABLE.
import { ADMIN_SCOPE, REDACTED } from './config.mjs';
import { MOCK_STATE_DIR, defaultWorkspaceDir } from './agents.mjs';
import { mcpEffectiveTools, mcpNotices } from './mcp.mjs';

export const SKILLS_METHODS = ['skills.status', 'skills.search', 'skills.detail', 'skills.install', 'skills.update'];
export const TOOLS_METHODS = ['tools.catalog', 'tools.effective'];
const ADMIN_METHODS = new Set(['skills.install', 'skills.update']);
const READ_SCOPE = 'operator.read';

export const CLAWHUB_REGISTRY = 'https://clawhub.ai';
export const MANAGED_SKILLS_DIR = `${MOCK_STATE_DIR}/skills`;
export const BUNDLED_SKILLS_DIR = '/opt/homebrew/lib/node_modules/openclaw/skills';
export const MOCK_PLATFORM = 'darwin';
const SKILLS_SH_TRUST_STATE = 'not-scanned-by-clawhub';

export function skillsDisabled() {
  return process.env.MOCK_NO_SKILLS === '1';
}
export function toolsDisabled() {
  return process.env.MOCK_NO_TOOLS === '1';
}
function clawHubOffline() {
  return process.env.MOCK_CLAWHUB_OFFLINE === '1';
}

// --- Seeds ---

const DAY = 24 * 60 * 60_000;

/**
 * The skill set every agent sees (upstream loads bundled + managed + the agent's workspace skills).
 * `metadata` is the SKILL.md frontmatter `metadata.openclaw` block.
 */
function seedSkillDefinitions(base) {
  return [
    {
      name: 'weather',
      description: 'Get current weather and forecasts (no API key required).',
      source: 'openclaw-bundled',
      metadata: { emoji: '🌤️', homepage: 'https://wttr.in/:help', requires: { bins: ['curl'] } },
    },
    {
      name: 'github',
      description: 'Interact with GitHub using the gh CLI: issues, pull requests, and CI runs.',
      source: 'openclaw-bundled',
      metadata: {
        emoji: '🐙',
        homepage: 'https://cli.github.com',
        requires: { bins: ['gh'] },
        install: [{ id: 'brew', kind: 'brew', formula: 'gh', bins: ['gh'], label: 'Install GitHub CLI (brew)' }],
      },
    },
    {
      name: 'video-frames',
      description: 'Extract frames or short clips from videos using ffmpeg.',
      source: 'openclaw-bundled',
      metadata: {
        emoji: '🎞️',
        homepage: 'https://ffmpeg.org',
        requires: { bins: ['ffmpeg'] },
        install: [{ id: 'brew', kind: 'brew', formula: 'ffmpeg', bins: ['ffmpeg'] }],
      },
    },
    {
      name: 'notion',
      description: 'Notion API for creating and managing pages, databases, and blocks.',
      source: 'openclaw-bundled',
      metadata: { emoji: '📝', homepage: 'https://developers.notion.com', primaryEnv: 'NOTION_API_KEY', requires: { env: ['NOTION_API_KEY'] } },
    },
    {
      name: 'voice-call',
      description: 'Start voice calls through the voice-call plugin.',
      source: 'openclaw-bundled',
      metadata: { emoji: '📞', requires: { config: ['plugins.entries.voice-call.enabled'] } },
    },
    {
      name: 'apple-notes',
      description: 'Manage Apple Notes from the terminal on macOS.',
      source: 'openclaw-bundled',
      metadata: { emoji: '🍎', os: ['darwin'] },
    },
    {
      name: 'apt-updates',
      description: 'Check for and apply Debian/Ubuntu package updates.',
      source: 'openclaw-bundled',
      metadata: { emoji: '📦', os: ['linux'], requires: { bins: ['apt-get'] } },
    },
    {
      name: 'slack',
      description: 'Control Slack from OpenClaw: react, pin, and send messages.',
      source: 'openclaw-bundled',
      metadata: { emoji: '💬', requires: { config: ['channels.slack'] } },
    },
    {
      name: 'openai-image-gen',
      description: 'Batch-generate images with the OpenAI Images API.',
      source: 'openclaw-bundled',
      metadata: { emoji: '🖼️', primaryEnv: 'OPENAI_API_KEY', requires: { env: ['OPENAI_API_KEY'] } },
    },
    {
      name: 'summarize',
      description: 'Summarize URLs, podcasts, and local files.',
      source: 'openclaw-managed',
      metadata: { emoji: '🧾', requires: { anyBins: ['uv', 'python3'] } },
    },
    {
      name: 'homelab-runbook',
      description: 'Runbooks for the home lab: NAS, Raspberry Pis, and backups.',
      source: 'openclaw-workspace',
      metadata: { emoji: '🏠' },
    },
    {
      name: 'nas-report',
      description: 'Summarize Synology NAS health: disks, volumes, and scrubs.',
      source: 'openclaw-workspace',
      metadata: { emoji: '🗄️', requires: { bins: ['ssh'] } },
      clawhub: { slug: 'nas-report', ownerHandle: 'clawdia', installedVersion: '1.2.0', installedAt: base - 30 * DAY },
    },
    {
      name: 'grocery-list',
      description: 'Keep a shared grocery list in Apple Reminders.',
      source: 'openclaw-workspace',
      metadata: { emoji: '🛒', os: ['darwin'] },
      clawhub: { slug: 'grocery-list', ownerHandle: 'clawdia', installedVersion: '0.9.0', installedAt: base - 60 * DAY },
      locallyModified: true,
    },
  ];
}

/** ClawHub's canned registry: what skills.search / skills.detail / clawhub installs resolve. */
function seedClawHubCatalog(base) {
  return [
    {
      slug: 'nas-report',
      ownerHandle: 'clawdia',
      displayName: 'NAS Report',
      summary: 'Summarize Synology NAS health: disks, volumes, and scrubs.',
      version: '1.3.0',
      createdAt: base - 200 * DAY,
      updatedAt: base - 2 * DAY,
      changelog: 'Adds Btrfs scrub history and SMART warnings as a table.',
      tags: { latest: '1.3.0' },
      metadata: { requires: { bins: ['ssh'] }, emoji: '🗄️' },
      owner: { handle: 'clawdia', displayName: 'Clawdia', official: false },
      description: 'Summarize Synology NAS health: disks, volumes, and scrubs.',
    },
    {
      slug: 'grocery-list',
      ownerHandle: 'clawdia',
      displayName: 'Grocery List',
      summary: 'Keep a shared grocery list in Apple Reminders.',
      version: '1.0.0',
      createdAt: base - 300 * DAY,
      updatedAt: base - 10 * DAY,
      changelog: 'Groups items by aisle.',
      tags: { latest: '1.0.0' },
      os: ['darwin'],
      metadata: { os: ['darwin'], emoji: '🛒' },
      owner: { handle: 'clawdia', displayName: 'Clawdia', official: false },
    },
    {
      slug: 'home-assistant',
      ownerHandle: 'openclaw',
      displayName: 'Home Assistant',
      summary: 'Control lights, climate, and scenes through the Home Assistant REST API.',
      version: '2.4.1',
      createdAt: base - 400 * DAY,
      updatedAt: base - 5 * DAY,
      changelog: 'Supports areas and floors.',
      tags: { latest: '2.4.1' },
      isOfficial: true,
      metadata: { primaryEnv: 'HASS_TOKEN', requires: { env: ['HASS_TOKEN'] }, emoji: '🏡' },
      owner: { handle: 'openclaw', displayName: 'OpenClaw', official: true },
    },
    {
      slug: 'plex-now-playing',
      ownerHandle: 'mediafan',
      displayName: 'Plex Now Playing',
      summary: "See what's playing on your Plex server and who is watching.",
      version: '0.6.0',
      createdAt: base - 90 * DAY,
      updatedAt: base - 20 * DAY,
      tags: { latest: '0.6.0' },
      metadata: { requires: { bins: ['curl'] }, emoji: '🎬' },
      owner: { handle: 'mediafan', displayName: 'Media Fan', official: false },
    },
    {
      slug: 'pi-fleet',
      ownerHandle: 'pilab',
      displayName: 'Pi Fleet',
      summary: 'Check uptime, temperature, and disk on a fleet of Raspberry Pis over SSH.',
      version: '1.1.0',
      createdAt: base - 150 * DAY,
      updatedAt: base - 40 * DAY,
      tags: { latest: '1.1.0' },
      os: ['darwin', 'linux'],
      metadata: { os: ['darwin', 'linux'], requires: { bins: ['ssh'] }, emoji: '🥧' },
      owner: { handle: 'pilab', displayName: 'Pi Lab', official: false },
    },
    {
      slug: 'obsidian-daily',
      ownerHandle: 'vaultsmith',
      displayName: 'Obsidian Daily Notes',
      summary: "Append to today's Obsidian daily note.",
      version: '0.3.2',
      createdAt: base - 50 * DAY,
      updatedAt: base - 3 * DAY,
      skillsSh: 'skills-sh:vaultsmith/obsidian-skills/obsidian-daily',
      metadata: { emoji: '🪨' },
    },
  ];
}

/** Host facts the status evaluator checks against. */
function seedHost() {
  return {
    bins: new Set(['curl', 'git', 'jq', 'ssh', 'python3', 'node', 'tmux', 'brew']),
    env: new Set(['OPENAI_API_KEY']),
    // Truthy config paths (isSkillConfigPathTruthy).
    config: new Set(['channels.slack', 'channels.discord']),
    // skills.allowBundled: only these bundled skills may load.
    allowBundled: ['weather', 'github', 'video-frames', 'notion', 'voice-call', 'apple-notes', 'apt-updates', 'slack'],
  };
}

export function createSkillsState(base = Date.now()) {
  return {
    definitions: seedSkillDefinitions(base),
    catalog: seedClawHubCatalog(base),
    host: seedHost(),
    // skills.entries.<skillKey> in openclaw.json.
    entries: new Map([['slack', { enabled: false }]]),
    // agents.entries.<id>.skills: the agent skill filter.
    agentSkillFilters: new Map([['research', ['weather', 'summarize', 'github', 'notion']]]),
  };
}

function skillsState(state) {
  state.skillsState ??= createSkillsState();
  return state.skillsState;
}

// --- Params schema (closed objects, like the gateway-protocol typebox schemas) ---

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fieldType = {
  nonEmpty: (v) => (typeof v !== 'string' ? 'must be string' : v.length ? undefined : 'must NOT have fewer than 1 characters'),
  string: (v) => (typeof v === 'string' ? undefined : 'must be string'),
  minString: (v) => fieldType.nonEmpty(v),
  boolean: (v) => (typeof v === 'boolean' ? undefined : 'must be boolean'),
  limit: (v) => (!Number.isInteger(v) ? 'must be integer' : v < 1 ? 'must be >= 1' : v > 100 ? 'must be <= 100' : undefined),
  timeoutMs: (v) => (!Number.isInteger(v) ? 'must be integer' : v < 1000 ? 'must be >= 1000' : undefined),
  sha256: (v) => (typeof v === 'string' && /^[a-fA-F0-9]{64}$/.test(v) ? undefined : 'must match pattern "^[a-fA-F0-9]{64}$"'),
  clawhub: (v) => (v === 'clawhub' ? undefined : 'must be equal to constant'),
  upload: (v) => (v === 'upload' ? undefined : 'must be equal to constant'),
  envRecord: (v) => {
    if (!isObject(v)) return 'must be object';
    for (const [key, value] of Object.entries(v)) {
      if (!key.length) return 'must NOT have fewer than 1 characters';
      if (typeof value !== 'string') return 'must be string';
    }
    return undefined;
  },
};

const SCHEMAS = {
  'skills.status': [{ fields: { agentId: 'nonEmpty', sessionKey: 'nonEmpty' } }],
  'skills.search': [{ fields: { query: 'nonEmpty', limit: 'limit' } }],
  'skills.detail': [{ required: ['slug'], fields: { slug: 'minString', version: 'minString' } }],
  'skills.install': [
    { required: ['name', 'installId'], fields: { agentId: 'nonEmpty', name: 'nonEmpty', installId: 'nonEmpty', dangerouslyForceUnsafeInstall: 'boolean', timeoutMs: 'timeoutMs' } },
    { required: ['source', 'slug'], fields: { agentId: 'nonEmpty', source: 'clawhub', slug: 'minString', version: 'nonEmpty', force: 'boolean', timeoutMs: 'timeoutMs' } },
    { required: ['source', 'uploadId', 'slug'], fields: { agentId: 'nonEmpty', source: 'upload', uploadId: 'nonEmpty', slug: 'nonEmpty', force: 'boolean', sha256: 'sha256', timeoutMs: 'timeoutMs' } },
  ],
  'skills.update': [
    { required: ['skillKey'], fields: { skillKey: 'nonEmpty', enabled: 'boolean', apiKey: 'string', env: 'envRecord' } },
    { required: ['source'], fields: { agentId: 'nonEmpty', source: 'clawhub', slug: 'nonEmpty', all: 'boolean', force: 'boolean' } },
  ],
  'tools.catalog': [{ fields: { agentId: 'nonEmpty', includePlugins: 'boolean' } }],
  'tools.effective': [{ required: ['sessionKey'], fields: { agentId: 'nonEmpty', sessionKey: 'nonEmpty' } }],
};

function closedObjectProblem(schema, params) {
  for (const key of schema.required ?? []) if (!(key in params)) return `at root: must have required property '${key}'`;
  for (const [key, value] of Object.entries(params)) {
    const type = schema.fields[key];
    if (!type) return `at root: unexpected property '${key}'`;
    const problem = fieldType[type](value);
    if (problem) return `at /${key}: ${problem}`;
  }
  return undefined;
}

export function skillsParamsProblem(method, params) {
  const variants = SCHEMAS[method];
  if (!isObject(params)) return 'at root: must be object';
  const problems = variants.map((schema) => closedObjectProblem(schema, params));
  if (problems.some((p) => p === undefined)) return undefined;
  // A union reports the variant whose discriminator matched, else the first variant's problem.
  if (variants.length > 1) {
    if (!('source' in params)) return problems[0];
    const index = variants.findIndex((schema) => schema.fields.source && params.source === (schema.fields.source === 'clawhub' ? 'clawhub' : 'upload'));
    if (index >= 0) return problems[index];
    return 'at root: must match a schema in anyOf';
  }
  return problems[0];
}

// --- Skill status (prepareWorkspaceSkillStatus) ---

function agentWorkspace(state, agentId) {
  return state.agents.get(agentId)?.workspace ?? defaultWorkspaceDir(agentId);
}

function skillPaths(def, workspaceDir) {
  const baseDir =
    def.source === 'openclaw-bundled'
      ? `${BUNDLED_SKILLS_DIR}/${def.name}`
      : def.source === 'openclaw-managed'
        ? `${MANAGED_SKILLS_DIR}/${def.name}`
        : `${workspaceDir}/skills/${def.name}`;
  return { baseDir, filePath: `${baseDir}/SKILL.md` };
}

function installOptions(def, host) {
  const specs = (def.metadata.install ?? []).filter((spec) => !spec.os || spec.os.includes(MOCK_PLATFORM));
  if (!specs.length) return [];
  // selectPreferredInstallSpec: the first spec whose installer is present (brew is).
  const spec = specs.find((s) => s.kind !== 'brew' || host.bins.has('brew')) ?? specs[0];
  const index = def.metadata.install.indexOf(spec);
  const label = spec.label ?? (spec.kind === 'brew' ? `Install ${spec.formula} (brew)` : 'Run installer');
  return [{ id: spec.id ?? `${spec.kind}-${index}`, kind: spec.kind, label, bins: spec.bins ?? [] }];
}

function statusEntry(skills, def, workspaceDir, agentId) {
  const { host } = skills;
  const skillKey = def.name;
  const entry = skills.entries.get(skillKey);
  const meta = def.metadata;
  const required = {
    bins: meta.requires?.bins ?? [],
    anyBins: meta.requires?.anyBins ?? [],
    env: meta.requires?.env ?? [],
    config: meta.requires?.config ?? [],
    os: meta.os ?? [],
  };
  const envSatisfied = (name) =>
    host.env.has(name) || Boolean(entry?.env?.[name]) || (name === meta.primaryEnv && Boolean(entry?.apiKey));
  const missing = {
    bins: required.bins.filter((bin) => !host.bins.has(bin)),
    anyBins: required.anyBins.length === 0 || required.anyBins.some((bin) => host.bins.has(bin)) ? [] : required.anyBins,
    env: required.env.filter((name) => !envSatisfied(name)),
    config: required.config.filter((path) => !host.config.has(path)),
    os: required.os.length && !required.os.includes(MOCK_PLATFORM) ? required.os : [],
  };
  const configChecks = required.config.map((path) => ({ path, satisfied: host.config.has(path) }));
  const satisfied = Object.values(missing).every((list) => list.length === 0);
  const disabled = entry?.enabled === false;
  const bundled = def.source === 'openclaw-bundled';
  const blockedByAllowlist = bundled && Array.isArray(host.allowBundled) && !host.allowBundled.includes(def.name);
  const filter = skills.agentSkillFilters.get(agentId);
  const blockedByAgentFilter = filter !== undefined && !filter.includes(def.name);
  const eligible = !disabled && !blockedByAllowlist && satisfied;
  const available = eligible && !blockedByAgentFilter;
  const { baseDir, filePath } = skillPaths(def, workspaceDir);
  const clawhub = def.clawhub
    ? {
        slug: def.clawhub.slug,
        ownerHandle: def.clawhub.ownerHandle,
        registry: CLAWHUB_REGISTRY,
        installedVersion: def.clawhub.installedVersion,
        installedAt: def.clawhub.installedAt,
        status: 'linked',
        valid: true,
        originPath: `${baseDir}/.clawhub/origin.json`,
        lockPath: `${workspaceDir}/.clawhub/lock.json`,
      }
    : undefined;
  return {
    name: def.name,
    description: def.description,
    source: def.source,
    bundled,
    filePath,
    baseDir,
    skillKey,
    ...(meta.primaryEnv ? { primaryEnv: meta.primaryEnv } : {}),
    ...(meta.emoji ? { emoji: meta.emoji } : {}),
    ...(meta.homepage ? { homepage: meta.homepage } : {}),
    always: meta.always === true,
    disabled,
    blockedByAllowlist,
    blockedByAgentFilter,
    eligible,
    platformIncompatible: missing.os.length > 0,
    modelVisible: available,
    userInvocable: true,
    commandVisible: available,
    requirements: required,
    missing,
    configChecks,
    install: installOptions(def, host),
    ...(clawhub ? { clawhub } : {}),
  };
}

export function skillsStatusReport(state, agentId) {
  const skills = skillsState(state);
  const workspaceDir = agentWorkspace(state, agentId);
  const filter = skills.agentSkillFilters.get(agentId);
  return {
    workspaceDir,
    managedSkillsDir: MANAGED_SKILLS_DIR,
    agentId,
    ...(filter ? { agentSkillFilter: [...filter] } : {}),
    skills: skills.definitions.map((def) => statusEntry(skills, def, workspaceDir, agentId)),
  };
}

// Mirrors redactConfigObject: sensitive keys become the redaction sentinel.
const SENSITIVE_KEY_RE = /(api[-_]?key|token|secret|password|passwd|credential)/i;
function redactEntry(entry) {
  const out = structuredClone(entry);
  if (typeof out.apiKey === 'string') out.apiKey = REDACTED;
  if (out.env) for (const key of Object.keys(out.env)) if (SENSITIVE_KEY_RE.test(key)) out.env[key] = REDACTED;
  return out;
}

function patchSkillEntry(skills, params) {
  const current = { ...(skills.entries.get(params.skillKey) ?? {}) };
  if (typeof params.enabled === 'boolean') current.enabled = params.enabled;
  if (typeof params.apiKey === 'string') {
    const trimmed = params.apiKey.trim();
    if (trimmed === REDACTED) {
      // A redacted round-trip keeps the stored secret.
    } else if (trimmed) current.apiKey = trimmed;
    else delete current.apiKey;
  }
  if (isObject(params.env)) {
    const env = { ...(current.env ?? {}) };
    for (const [rawKey, rawValue] of Object.entries(params.env)) {
      const key = rawKey.trim();
      if (!key) continue;
      const value = rawValue.trim();
      if (value === REDACTED) continue;
      if (!value) delete env[key];
      else env[key] = value;
    }
    current.env = env;
  }
  skills.entries.set(params.skillKey, current);
  return current;
}

// --- ClawHub ---

/** parseRequestedClawHubSkillRef: `@owner/slug`, `skills-sh:owner/repo/slug`, or bare `slug`. */
function parseSkillRef(raw) {
  const value = String(raw).trim();
  if (value.startsWith('skills-sh:')) return { slug: value.split('/').pop(), requestedReference: value };
  const scoped = /^@([^/\s]+)\/([^/\s]+)$/.exec(value);
  if (scoped) return { ownerHandle: scoped[1], slug: scoped[2] };
  return { slug: value };
}

function searchResult(item, score) {
  const base = {
    score,
    slug: item.slug,
    registry: CLAWHUB_REGISTRY,
    displayName: item.displayName,
    ...(item.summary ? { summary: item.summary } : {}),
    icon: null,
    version: item.version,
    updatedAt: item.updatedAt,
  };
  if (item.skillsSh) return { ...base, ownerHandle: null, installRef: item.skillsSh, installOnly: true, trustState: SKILLS_SH_TRUST_STATE };
  return { ...base, ownerHandle: item.ownerHandle, installRef: `@${item.ownerHandle}/${item.slug}` };
}

function searchScore(item, query) {
  const q = query.toLowerCase();
  const hay = [item.slug, item.displayName, item.summary ?? ''].map((s) => s.toLowerCase());
  if (hay[0] === q || hay[1] === q) return 1;
  if (hay[0].includes(q) || hay[1].includes(q)) return 0.8;
  if (hay[2].includes(q)) return 0.5;
  return 0;
}

export function skillsSearch(state, { query, limit }) {
  const { catalog } = skillsState(state);
  const q = query?.trim();
  if (!q) return catalog.slice(0, Math.min(limit ?? 20, 100)).map((item) => searchResult(item, 0));
  return catalog
    .map((item) => ({ item, score: searchScore(item, q) }))
    .filter(({ score }) => score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit ?? 20)
    .map(({ item, score }) => searchResult(item, score));
}

function detailPayload(item, selectedVersion = item.version) {
  const latestVersion = { version: item.version, createdAt: item.updatedAt, ...(item.changelog ? { changelog: item.changelog } : {}) };
  return {
    skill: {
      slug: item.slug,
      displayName: item.displayName,
      ...(item.summary ? { summary: item.summary } : {}),
      icon: null,
      tags: item.tags ?? {},
      channel: null,
      isOfficial: item.isOfficial ?? false,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
    },
    latestVersion,
    selectedRelease: selectedVersion === item.version ? latestVersion : null,
    metadata: { os: item.os ?? null, systems: null },
    owner: item.owner ? { ...item.owner, image: null } : null,
  };
}

function findCatalogItem(catalog, ref) {
  return catalog.find((item) => !item.skillsSh && item.slug === ref.slug && (!ref.ownerHandle || item.ownerHandle === ref.ownerHandle));
}

// --- Tools (tools.catalog / tools.effective) ---

/** A slice of CORE_TOOL_DEFINITIONS (src/agents/tool-catalog.ts), in section order. */
const CORE_TOOLS = [
  ['fs', 'Files', [
    ['read', 'Read file contents', ['coding']],
    ['write', 'Create or overwrite files', ['coding']],
    ['edit', 'Make precise edits', ['coding']],
    ['apply_patch', 'Patch files', ['coding']],
  ]],
  ['runtime', 'Runtime', [
    ['exec', 'Run shell commands', ['coding']],
    ['process', 'Manage background processes', ['coding']],
    ['code_execution', 'Run sandboxed remote analysis', ['coding']],
  ]],
  ['web', 'Web', [
    ['web_search', 'Search the web', ['coding']],
    ['web_fetch', 'Fetch web content', ['coding']],
    ['x_search', 'Search X posts', ['coding']],
  ]],
  ['memory', 'Memory', [
    ['memory_search', 'Semantic search', ['coding']],
    ['memory_get', 'Read memory files', ['coding']],
  ]],
  ['sessions', 'Sessions', [
    ['sessions_list', 'List sessions', ['coding', 'messaging']],
    ['sessions_history', 'Read session history', ['coding', 'messaging']],
    ['sessions_send', 'Send to another session', ['coding', 'messaging']],
    ['sessions_spawn', 'Spawn a sub-agent session', ['coding', 'messaging']],
    ['session_status', 'Session status and usage', ['minimal', 'coding', 'messaging']],
  ]],
  ['ui', 'UI', [
    ['browser', 'Control web browser', []],
    ['canvas', 'Present and edit canvases', []],
  ]],
  ['messaging', 'Messaging', [['message', 'Send messages and channel actions', ['messaging']]]],
  ['automation', 'Automation', [
    ['cron', 'Schedule jobs and reminders', ['coding']],
    ['gateway', 'Gateway control', []],
  ]],
  ['nodes', 'Nodes', [['nodes', 'Paired nodes: camera, screen, location, notify', []]]],
  ['media', 'Media', [['image', 'Understand images', ['coding']]]],
];
const PLUGIN_TOOLS = [
  { pluginId: 'voice-call', label: 'Voice Call', tools: [{ id: 'voice_call', description: 'Place and control phone calls', optional: true, risk: 'high' }] },
  { pluginId: 'lobster', label: 'Lobster', tools: [{ id: 'lobster', description: 'Run typed workflow pipelines with resumable approvals', risk: 'medium' }] },
];
const PROFILE_OPTIONS = [
  { id: 'minimal', label: 'Minimal' },
  { id: 'coding', label: 'Coding' },
  { id: 'messaging', label: 'Messaging' },
  { id: 'full', label: 'Full' },
];

/**
 * Tool policy per agent (openclaw.json tools.* / agents.entries.<id>.tools.*): main uses the coding
 * profile with a deny list, research an explicit allowlist, coder the full profile.
 */
const AGENT_TOOL_POLICIES = {
  main: { profile: 'coding', profileSource: 'tools.profile', deny: ['x_search', 'code_execution'], denySource: 'tools.deny', alsoAllowPath: 'tools.alsoAllow', plugins: ['lobster'] },
  research: {
    profile: 'coding',
    profileSource: 'tools.profile',
    allow: ['read', 'web_search', 'web_fetch', 'memory_search', 'memory_get', 'sessions_list', 'session_status'],
    allowSource: 'agents.entries.research.tools.allow',
    alsoAllowPath: 'agents.entries.research.tools.alsoAllow',
    plugins: [],
  },
  coder: { profile: 'full', profileSource: 'agents.entries.coder.tools.profile', plugins: ['lobster', 'voice-call'] },
};
// Session tool overrides (sessions.patch toolOverrides): the Discord channel can't run commands.
const SESSION_DENY = { 'agent:main:discord:channel:123': ['exec', 'process'] };
const CHANNEL_TOOLS = { discord: [{ id: 'discord_react', description: 'React to a Discord message' }] };

function agentPolicy(agentId) {
  return AGENT_TOOL_POLICIES[agentId] ?? { profile: 'coding', profileSource: 'tools.profile', plugins: [] };
}

export function toolsCatalogPayload(agentId, includePlugins = true) {
  const groups = CORE_TOOLS.map(([id, label, tools]) => ({
    id,
    label,
    source: 'core',
    tools: tools.map(([toolId, description, defaultProfiles]) => ({ id: toolId, label: toolId, description, source: 'core', defaultProfiles })),
  }));
  if (includePlugins) {
    for (const plugin of PLUGIN_TOOLS) {
      groups.push({
        id: `plugin:${plugin.pluginId}`,
        label: plugin.label,
        source: 'plugin',
        pluginId: plugin.pluginId,
        tools: plugin.tools.map((tool) => ({
          id: tool.id,
          label: tool.id,
          description: tool.description,
          source: 'plugin',
          pluginId: plugin.pluginId,
          ...(tool.optional ? { optional: true } : {}),
          ...(tool.risk ? { risk: tool.risk } : {}),
          defaultProfiles: [],
        })),
      });
    }
  }
  return { agentId, profiles: PROFILE_OPTIONS.map((p) => ({ ...p })), groups };
}

function inProfile(profile, profiles) {
  return profile === 'full' || profiles.includes(profile);
}

export function toolsEffectivePayload(agentId, sessionKey, state) {
  const policy = agentPolicy(agentId);
  const sessionDeny = new Set(SESSION_DENY[sessionKey] ?? []);
  const channel = /^agent:[^:]+:(discord|slack|telegram|whatsapp):/.exec(sessionKey)?.[1];
  const access = [];
  const core = [];
  for (const [, , tools] of CORE_TOOLS) {
    for (const [id, description, profiles] of tools) {
      const reasons = [];
      if (!inProfile(policy.profile, profiles)) reasons.push({ kind: 'profile', label: `${policy.profile} profile`, source: policy.profileSource, profile: policy.profile });
      if (policy.deny?.includes(id)) reasons.push({ kind: 'deny', label: `Denied by ${policy.denySource}`, source: policy.denySource });
      if (policy.allow && !policy.allow.includes(id)) reasons.push({ kind: 'allowlist', label: `Not included in ${policy.allowSource}`, source: policy.allowSource });
      const policyAllowed = reasons.length === 0;
      if (policyAllowed && sessionDeny.has(id)) {
        // Session overrides keep the tool listed but mark it; toolAccess says why.
        core.push({ id, label: id, description, rawDescription: description, source: 'core', deniedBySession: true });
        access.push({ id, status: 'excluded', reasons: [{ kind: 'session', label: 'Denied by session tool overrides', source: 'session.toolOverrides' }] });
        continue;
      }
      if (policyAllowed) {
        core.push({ id, label: id, description, rawDescription: description, source: 'core' });
        access.push({ id, status: 'available', reasons: [] });
        continue;
      }
      const tool = { id, status: 'excluded', reasons };
      if (reasons.length === 1 && reasons[0].kind === 'profile' && policy.alsoAllowPath) tool.alsoAllowPath = policy.alsoAllowPath;
      access.push(tool);
    }
  }
  const groups = [{ id: 'core', label: 'Built-in tools', source: 'core', tools: core }];
  const pluginTools = PLUGIN_TOOLS.filter((p) => policy.plugins.includes(p.pluginId)).flatMap((p) =>
    p.tools.map((tool) => ({
      id: tool.id,
      label: tool.id,
      description: tool.description,
      rawDescription: tool.description,
      source: 'plugin',
      pluginId: p.pluginId,
      ...(tool.risk ? { risk: tool.risk } : {}),
    })),
  );
  if (pluginTools.length) groups.push({ id: 'plugin', label: 'Plugin tools', source: 'plugin', tools: pluginTools });
  if (channel && CHANNEL_TOOLS[channel]) {
    groups.push({
      id: 'channel',
      label: 'Channel tools',
      source: 'channel',
      tools: CHANNEL_TOOLS[channel].map((tool) => ({ ...tool, label: tool.id, rawDescription: tool.description, source: 'channel', channelId: channel })),
    });
  }
  if (policy.profile === 'full' || agentId === 'main') {
    groups.push({
      id: 'mcp',
      label: 'MCP tools',
      source: 'mcp',
      tools: mcpEffectiveTools(state).map((tool) => ({
        id: `${tool.safeServer}__${tool.tool}`,
        label: tool.tool,
        description: tool.description,
        rawDescription: tool.description,
        source: 'mcp',
        mcpServer: tool.server,
        mcpToolName: tool.tool,
        ...(tool.risk ? { risk: tool.risk } : {}),
      })),
    });
  }
  const available = groups.flatMap((g) => g.tools.filter((t) => !t.deniedBySession).map((t) => t.id));
  for (const id of available) if (!access.some((a) => a.id === id)) access.push({ id, status: 'available', reasons: [] });
  const notices = [];
  if (policy.profile !== 'full') {
    notices.push({
      id: 'browser-filtered-by-profile',
      severity: 'info',
      message:
        'Browser is configured, but the current tool profile does not include the browser tool. Add tools.alsoAllow: ["browser"] or agents.entries.*.tools.alsoAllow: ["browser"]; tools.subagents.tools.allow alone cannot add it back after profile filtering.',
    });
  }
  if (agentId === 'main') notices.push(...mcpNotices(state));
  return {
    agentId,
    profile: policy.profile,
    groups,
    ...(notices.length ? { notices } : {}),
    toolAccess: {
      checked: 'live-session',
      profiles: [{ profile: policy.profile, source: policy.profileSource, active: true }],
      tools: access,
    },
  };
}

// --- Handler ---

function scopeApproved(scopes, scope) {
  return scopes.includes(scope) || scopes.includes(ADMIN_SCOPE) || (scope === READ_SCOPE && scopes.includes('operator.write'));
}

function sessionAgentId(sessionKey) {
  return /^agent:([^:]+):/.exec(sessionKey)?.[1] ?? 'main';
}

export function handleSkillsRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  const isSkills = SKILLS_METHODS.includes(method);
  const isTools = TOOLS_METHODS.includes(method);
  if (!isSkills && !isTools) return false;
  if ((isSkills && skillsDisabled()) || (isTools && toolsDisabled())) return false;
  const params = msg.params ?? {};
  const required = ADMIN_METHODS.has(method) ? ADMIN_SCOPE : READ_SCOPE;
  if (!scopeApproved(conn.scopes ?? [], required)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${required}`, { code: 'MISSING_SCOPE', scope: required });
    return true;
  }
  const invalid = (message, details) => (sendErr(conn, id, 'INVALID_REQUEST', message, details), true);
  const unavailable = (message, details) => (sendErr(conn, id, 'UNAVAILABLE', message, details), true);
  const problem = skillsParamsProblem(method, params);
  if (problem) return invalid(`invalid ${method} params: ${problem}`);
  const skills = skillsState(state);
  // resolveSkillsAgentWorkspace / resolveAgentIdOrRespondError.
  const resolveAgent = () => {
    const raw = params.agentId?.trim();
    if (raw && !state.agents.has(raw.toLowerCase())) return { error: `unknown agent id "${raw}"` };
    return { agentId: raw ? raw.toLowerCase() : state.agents.has('main') ? 'main' : [...state.agents.keys()][0] };
  };

  switch (method) {
    case 'skills.status': {
      const resolved = resolveAgent();
      if (resolved.error) return invalid(resolved.error);
      if (params.sessionKey && !state.sessions.has(params.sessionKey)) return invalid('Session not found.');
      sendRes(conn, id, skillsStatusReport(state, resolved.agentId));
      return true;
    }
    case 'skills.search': {
      if (clawHubOffline()) return unavailable('ClawHub request failed: fetch failed');
      sendRes(conn, id, { results: skillsSearch(state, params) });
      return true;
    }
    case 'skills.detail': {
      const ref = parseSkillRef(params.slug);
      if (ref.requestedReference) {
        return invalid(
          `ClawHub cannot return details for ${ref.requestedReference}; external skill sources are install-only. Install it directly, or run "openclaw skills install ${ref.requestedReference}".`,
        );
      }
      if (clawHubOffline()) return unavailable('ClawHub request failed: fetch failed');
      const item = findCatalogItem(skills.catalog, ref);
      if (!item) return unavailable(`ClawHub /api/v1/skills/${encodeURIComponent(ref.slug)} failed (404): Skill not found`);
      sendRes(conn, id, detailPayload(item, params.version?.trim() || item.version));
      return true;
    }
    case 'skills.install': {
      const resolved = resolveAgent();
      if (resolved.error) return invalid(resolved.error);
      const workspaceDir = agentWorkspace(state, resolved.agentId);
      if (params.source === 'upload') return unavailable(`Upload not found: ${params.uploadId}`);
      if (params.source === 'clawhub') {
        if (clawHubOffline()) return unavailable('ClawHub request failed: fetch failed');
        const ref = parseSkillRef(params.slug);
        const item = ref.requestedReference
          ? skills.catalog.find((c) => c.skillsSh === ref.requestedReference)
          : findCatalogItem(skills.catalog, ref);
        if (!item) return unavailable(`ClawHub /api/v1/skills/${encodeURIComponent(ref.slug)} failed (404): Skill not found`);
        const existing = skills.definitions.find((d) => d.name === item.slug);
        if (existing && !params.force) {
          return unavailable(`Skill "${item.slug}" is already installed at ${skillPaths(existing, workspaceDir).baseDir}. Re-run with force to replace it.`);
        }
        const version = params.version ?? item.version;
        const def = {
          name: item.slug,
          description: item.summary ?? item.displayName,
          source: 'openclaw-workspace',
          metadata: structuredClone(item.metadata ?? {}),
          clawhub: { slug: item.slug, ownerHandle: item.ownerHandle, installedVersion: version, installedAt: Date.now() },
        };
        if (existing) skills.definitions.splice(skills.definitions.indexOf(existing), 1, def);
        else skills.definitions.push(def);
        const warning = item.skillsSh ? `${item.skillsSh} was not scanned by ClawHub. Review it before use.` : undefined;
        sendRes(conn, id, {
          ok: true,
          message: `Installed ${item.slug}@${version}`,
          stdout: '',
          stderr: '',
          code: 0,
          slug: item.slug,
          version,
          targetDir: `${workspaceDir}/skills/${item.slug}`,
          ...(warning ? { warning } : {}),
        });
        return true;
      }
      const def = skills.definitions.find((d) => d.name === params.name);
      if (!def) return unavailable(`Skill not found: ${params.name}`);
      const option = installOptions(def, skills.host).find((o) => o.id === params.installId);
      const spec = (def.metadata.install ?? []).find((s, index) => (s.id ?? `${s.kind}-${index}`) === params.installId);
      if (!option || !spec) return unavailable(`Installer not found: ${params.installId}`);
      for (const bin of spec.bins ?? []) skills.host.bins.add(bin);
      sendRes(conn, id, {
        ok: true,
        message: 'Installed',
        stdout: `==> Fetching ${spec.formula}\n==> Pouring ${spec.formula}--latest.arm64_sequoia.bottle.tar.gz\n🍺  /opt/homebrew/Cellar/${spec.formula}: installed`,
        stderr: '',
        code: 0,
      });
      return true;
    }
    case 'skills.update': {
      if (params.source !== 'clawhub') {
        const entry = patchSkillEntry(skills, params);
        sendRes(conn, id, { ok: true, skillKey: params.skillKey, config: redactEntry(entry) });
        return true;
      }
      if (!params.slug && !params.all) return invalid('clawhub skills.update requires "slug" or "all"');
      if (params.slug && params.all) return invalid('clawhub skills.update accepts either "slug" or "all", not both');
      const resolved = resolveAgent();
      if (resolved.error) return invalid(resolved.error);
      if (clawHubOffline()) return unavailable('ClawHub request failed: fetch failed');
      const workspaceDir = agentWorkspace(state, resolved.agentId);
      const tracked = skills.definitions.filter((d) => d.clawhub);
      const targets = params.slug ? [parseSkillRef(params.slug).slug] : tracked.map((d) => d.clawhub.slug);
      const results = targets.map((slug) => {
        const def = tracked.find((d) => d.clawhub.slug === slug);
        if (!def) return { ok: false, error: `Skill "${slug}" is not installed from ClawHub in ${workspaceDir}.` };
        if (def.locallyModified && !params.force) {
          return {
            ok: false,
            code: 'force_required',
            error: `Skill "${slug}" has local changes since it was installed. Updating replaces the installed skill directory.`,
          };
        }
        const item = skills.catalog.find((c) => c.slug === slug);
        const previousVersion = def.clawhub.installedVersion ?? null;
        const version = item?.version ?? previousVersion;
        def.clawhub = { ...def.clawhub, installedVersion: version, installedAt: Date.now() };
        delete def.locallyModified;
        return { ok: true, slug, previousVersion, version, changed: previousVersion !== version, targetDir: `${workspaceDir}/skills/${slug}` };
      });
      const errors = results.filter((r) => !r.ok);
      if (errors.length) return unavailable(errors.map((r) => r.error).join('; '), { results });
      sendRes(conn, id, { ok: true, skillKey: params.slug ?? '*', config: { source: 'clawhub', results } });
      return true;
    }
    case 'tools.catalog': {
      const resolved = resolveAgent();
      if (resolved.error) return invalid(resolved.error);
      sendRes(conn, id, toolsCatalogPayload(resolved.agentId, params.includePlugins !== false));
      return true;
    }
    case 'tools.effective': {
      const resolved = params.agentId ? resolveAgent() : {};
      if (resolved.error) return invalid(resolved.error);
      if (!state.sessions.has(params.sessionKey)) return invalid(`unknown session key "${params.sessionKey}"`);
      const owner = sessionAgentId(params.sessionKey);
      if (resolved.agentId && resolved.agentId !== owner) {
        return invalid(`agent id "${resolved.agentId}" does not match session agent "${owner}"`);
      }
      sendRes(conn, id, toolsEffectivePayload(owner, params.sessionKey, state));
      return true;
    }
  }
  return false;
}
