# jobsearcher-deploy

Compose stack + helper scripts for the on-demand job-search pipeline. Pulls jobs
from `jobmcp`, gathers company context from `company-mcp`, drafts a per-job
briefing through OpenRouter, emails it via `gmail-mcp` (Resend), and pings
`slack-mcp`. The `job-search` skill drives the flow; `job-search-reply` drains
the yes/no/skip replies.

```
                                                        OpenRouter
                                                        ├ extractor (haiku-3.5)
   docker compose up                                    ├ synthesizer (opus-3)
   ──────────────────                                   └ agent (haiku-4.5)
                                                                 ▲
   ┌──────────┐  ┌──────────┐  ┌──────────────┐  ┌─────────────┐ │
   │ valkey   │◄─┤ jobmcp   │  │ company-mcp  │  │ gmail-mcp   │ │
   │ (state)  │  │ (search) │  │ (profile/news│  │ (Resend)    │ │
   └──────────┘  └────▲─────┘  │  /linkedin)  │  └──────┬──────┘ │
                      │        └──────▲───────┘         │        │
                      │               │                 │        │
                      └───────┬───────┴────────┬────────┘        │
                              │                │                 │
                       ┌──────┴──────┐  ┌──────┴──────┐    ┌─────┴────┐
                       │ slack-mcp   │  │ openclaw-   │◄───┤ openclaw │
                       │ (heads-ups) │  │ gateway     │    │ -cli     │
                       └─────────────┘  └─────────────┘    └──────────┘
```

## Quickstart

```sh
git clone --recurse-submodules https://github.com/<you>/jobsearcher-deploy.git
cd jobsearcher-deploy

cp .env.example .env
$EDITOR .env                              # fill in CHANGEME values

cp openclaw.template.json $HOME/.openclaw/openclaw.json   # one-time
mkdir -p $HOME/.openclaw/workspace/skills $HOME/.openclaw/workspace/scripts
# install helper that maintains the Valkey-backed processed-job set
cp scripts/processed.js  $HOME/.openclaw/workspace/scripts/processed.js

docker compose up -d                      # ~20s warm; ~10s after first boot

bash run-job-search.sh                    # default: dry-run=true, limit=1
MSG="/job-search dry-run=false limit=3" bash run-job-search.sh
MSG="/job-search-reply" bash run-job-search.sh    # process pending replies
```

## Scheduled runs (built-in cron)

OpenClaw's gateway has a cron scheduler — no separate watchdog container needed. Two jobs are typically registered:

```sh
# Daily 09:00 UTC pass — three real briefings.
docker compose exec openclaw-cli openclaw cron add \
    --name job-search-daily \
    --agent main \
    --message "/job-search dry-run=false limit=3" \
    --cron "0 9 * * *" --tz UTC \
    --timeout-seconds 900 --thinking medium \
    --expect-final --no-deliver --best-effort-deliver

# Every 30 min during 09–19 UTC — drain Slack yes/no/skip replies.
docker compose exec openclaw-cli openclaw cron add \
    --name job-search-replies \
    --agent main \
    --message "/job-search-reply" \
    --cron "*/30 9-19 * * *" --tz UTC \
    --timeout-seconds 300 --thinking minimal \
    --expect-final --no-deliver --best-effort-deliver

docker compose exec openclaw-cli openclaw cron list
docker compose exec openclaw-cli openclaw cron runs --id <job-id>
docker compose exec openclaw-cli openclaw cron run  <job-id>   # debug-trigger now
```

Use `--no-deliver` (as above) — the pipeline already sends emails and Slack heads-ups via tool calls, so the agent's wrap-up reply doesn't need a separate broadcast channel.

## Layout

| Path                         | What it is                                                         |
| ---------------------------- | ------------------------------------------------------------------ |
| `compose.yml`                | All 7 services: valkey, jobmcp, company-mcp, gmail-mcp, slack-mcp, openclaw-gateway, openclaw-cli. |
| `.env.example`               | Every var with placeholders. Real values go in `.env`.             |
| `openclaw.template.json`     | Sanitized openclaw config. Live edits go to `~/.openclaw/openclaw.json`. |
| `run-job-search.sh`          | Streams gateway/MCP/agent logs interleaved while running a skill. Includes a netns preflight that recreates the cli container so `network_mode: service:gateway` doesn't go stale after a gateway recreate. |
| `switch-openrouter-tier.sh`  | Flips `.env` + `openclaw.json` between `free` and `paid` OpenRouter model presets. Backs up both files. |
| `scripts/processed.js`       | Tiny RESP client used by the skills to maintain `jobsearch:processed` (a Valkey set of already-briefed job ids). Persists across days. |
| `jobmcp/`, `company-mcp/`, `gmail-mcp/` | Submodules. The slack-mcp container uses a published image. |

## Per-pipeline expectations

- **OpenRouter paid tier:** the heavy alias resolves to opus-class; budget on the order of $0.05–$0.15 per 3-job pass depending on briefing length. Cheap fallbacks kick in on rate limits.
- **Resend free tier:** only delivers to the account owner. If you change `MAIL_DEFAULT_TO` to anything other than your verified Resend address, the call returns a sandbox-restriction error — that's expected, not a code bug.

## Operational notes

### Boot

After the first container build, openclaw-gateway warms in ~10s. If you ever see it stalling for minutes, look for `.openclaw-runtime-deps.lock` in `~/.openclaw/plugin-runtime-deps/openclaw-*/` and remove it — that lock can confuse the install path when the container's own pid matches the recorded owner pid (same-pid collision after recreates).

### Avoid restarts

`openclaw-cli` joins `openclaw-gateway`'s netns via `network_mode: service:gateway`. When the gateway is recreated (image swap, model change, config push), the cli's netns goes stale silently — DNS and `127.0.0.1:18789` stop working. `run-job-search.sh` handles this by force-recreating the cli on every invocation. If you exec into the cli container outside that script, run `docker compose up -d --force-recreate --no-deps openclaw-cli` first whenever the gateway has restarted.

### Hot reload

Most `~/.openclaw/openclaw.json` edits are picked up live (gateway logs `[reload] config change detected`). Model and provider changes trigger an auto-restart at the next idle moment. You generally don't need `docker compose restart`.

## Skill dependencies

The bundled skills assume:

- `~/.openclaw/workspace/MEMORY.md` exists with `TARGET_ROLES`, `GEO_HARD_FILTERS`, `DEAL_BREAKERS`, `COMP`, `SENIORITY`.
- `~/.openclaw/workspace/cv.txt` exists.
- `~/.openclaw/workspace/skills/job-search/SKILL.md` and `~/.openclaw/workspace/skills/job-search-reply/SKILL.md` are present (commit them in your *workspace* repo, not this deploy repo).
- `~/.openclaw/workspace/scripts/processed.js` is installed (see Quickstart).

## Versioning your openclaw setup (workspace + config)

The deploy repo (this one) is for the *infrastructure* — compose stack, scripts, sanitized template. The actual openclaw runtime state lives in `~/.openclaw/` and is **not** tracked here. To replicate or sync your setup across machines you maintain a separate **workspace repo** plus a documented config-bootstrap procedure.

### What lives where

```
~/.openclaw/                         ← whole openclaw home (per-host, mostly state)
├── openclaw.json                    ← the gateway config — sensitive (api keys, tokens)
├── openclaw.json.bak-*              ← backups; do NOT commit
├── agents/main/
│   ├── agent/auth-profiles.json     ← API keys for providers — SENSITIVE
│   ├── sessions/*.jsonl             ← conversation history; transient
│   └── sessions/*.trajectory.jsonl  ← run traces; transient
├── cron/jobs.json                   ← scheduled jobs; replicable but per-host
├── plugin-runtime-deps/             ← npm caches; rebuild-on-boot, never commit
└── workspace/                       ← what your skills + agent personality live in ★
    ├── MEMORY.md                    ← your target profile, prefs, guardrails
    ├── cv.txt / cv.pdf              ← personal data
    ├── USER.md / IDENTITY.md / SOUL.md / TOOLS.md / AGENTS.md ← persona/context
    ├── memory/<date>.md             ← daily briefings logs (real msg ids — sensitive)
    ├── skills/<name>/SKILL.md       ← the actual skill definitions ★
    ├── scripts/                     ← skill helper scripts ★
    ├── .openclaw/                   ← runtime state; do NOT commit
    └── state/                       ← runtime state; do NOT commit
```

★ = the parts worth versioning.

### What's sensitive (never commit)

- `~/.openclaw/openclaw.json` — contains hex `OPENCLAW_GATEWAY_TOKEN`, OpenRouter base URL, and (on most installs) inlined API keys.
- `~/.openclaw/agents/*/agent/auth-profiles.json` — raw API keys per provider.
- Any `*.bak-*` file produced by tier-swap or manual edits.
- `memory/<date>.md` files — they record real Gmail message-IDs and Slack `ts` values for delivered briefings; not credentials but personally-correlatable.
- `cv.txt`, `cv.pdf`, `USER.md`, `MEMORY.md` — personal data. Keep these in a **private** repo.

### Recommended layout: two repos

1. **`jobsearcher-deploy`** (this repo, public) — compose stack, scripts, `.env.example`, `openclaw.template.json` (sanitized), MCP repos as submodules. No secrets.
2. **`openclaw-workspace`** (private) — your `~/.openclaw/workspace` directory committed to a private GitHub repo. Tracks: `MEMORY.md`, `USER.md`, `IDENTITY.md`, `SOUL.md`, `TOOLS.md`, `AGENTS.md`, `HEARTBEAT.md`, `cv.*`, `skills/**`, `scripts/**`, `memory/**`. Gitignores: `.openclaw/`, `state/`, `*.bak-*`.

`.gitignore` for the workspace repo:
```
*.bak-*
state/
.openclaw/
.DS_Store
*.swp
```

### Replicating on another machine

```sh
# 1. Clone the deploy repo (with submodules)
git clone --recurse-submodules git@github.com:chucheloff/jobsearcher-deploy.git
cd jobsearcher-deploy
cp .env.example .env && $EDITOR .env          # paste your secrets

# 2. Clone the private workspace repo into place
mkdir -p ~/.openclaw
git clone git@github.com:<you>/openclaw-workspace.git ~/.openclaw/workspace

# 3. Copy the sanitized config template, then add provider auth interactively
cp openclaw.template.json ~/.openclaw/openclaw.json
docker compose run --rm openclaw-cli openclaw auth set openrouter   # prompts
docker compose run --rm openclaw-cli openclaw auth set google       # if you use gemini

# 4. Bring everything up
docker compose up -d
docker compose exec openclaw-cli openclaw skills list                # verify ✓

# 5. Re-register cron jobs (gateway state, lives in ~/.openclaw/cron/jobs.json)
docker compose exec openclaw-cli openclaw cron add --name job-search-replies \
    --agent main --message "/job-search-reply" --cron "*/30 9-19 * * *" --tz UTC \
    --timeout-seconds 300 --thinking minimal --expect-final --no-deliver --best-effort-deliver
```

### Day-to-day: what changes are worth committing

Track in the workspace repo whenever you:
- Edit `MEMORY.md` (target roles, deal-breakers, etc.)
- Tweak any `skills/*/SKILL.md` (this is the bulk of agent behaviour)
- Add a new helper to `scripts/`
- Want to checkpoint a `memory/<date>.md` for audit (optional; these grow daily)

Track in the deploy repo (this one) whenever you:
- Change `compose.yml` (new MCP server, port change, env wiring)
- Update `run-job-search.sh` / `switch-openrouter-tier.sh`
- Bump submodule pins (`git -C <sub> pull` then `git add <sub>` here)
- Adjust `openclaw.template.json` (after a config change you want others to inherit — re-run the sanitize step before committing)

### Syncing two identically-configured agents

If you run the same agent on two machines:
- Workspace repo + branch of your choice on both — pull/push between them.
- Deploy repo on both — same.
- **Don't** sync `~/.openclaw/openclaw.json` directly — let each host have its own (they share token format from the template, not the literal token value).
- **Do** sync `~/.openclaw/cron/jobs.json` if you want the same schedules — but watch for clock-skew or duplicate runs if both hosts share an agent identity (they shouldn't).
- Per-host things to keep separate: `OPENCLAW_GATEWAY_TOKEN`, `auth-profiles.json`, `agents/*/sessions/`, `cron/jobs.json`, anything under `state/` or `plugin-runtime-deps/`.

### Quick sanitize before committing the template again

```sh
# Strip personal/runtime fields, keep schema-significant ones.
python3 -c "
import json
c=json.load(open('$HOME/.openclaw/openclaw.json'))
c.pop('meta',None)
json.dump(c, open('openclaw.template.json','w'), indent=2)
print('ok')
"
```

(`meta.lastTouchedAt` is the only changing field that drifts every restart and isn't useful in a template.)

## Switching tiers

```sh
bash switch-openrouter-tier.sh free       # flip both .env and openclaw.json
bash switch-openrouter-tier.sh paid       # back to anthropic models
```

The script backs up both files (`*.bak-YYYYMMDD-HHMMSS`) before mutating.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Agent says "command not found" for `jobmcp.*` (with a dot) | Outdated MEMORY.md | Use `jobmcp__*` (double-underscore) everywhere. |
| `jobmcp.search_jobs` itself returns "not found" | Tool not in `tools.alsoAllow` | Either add it or switch `tools.profile` from `minimal` to `messaging`. |
| `openclaw agent ... → connect ECONNREFUSED 127.0.0.1:18789` | cli netns stale after gateway recreate | `run-job-search.sh` handles automatically; otherwise `docker compose up -d --force-recreate --no-deps openclaw-cli`. |
| `OpenRouter pricing fetch failed (timeout 60s)` | Cosmetic — cli pulls model pricing on boot | Ignore unless other OpenRouter calls also fail. |
| Slack post fails with `not_in_channel` | Bot not added to the channel | In Slack: `/invite @JobSearcherBot` in the target channel. |
| Cron run fails with `402 You requested up to 32000 tokens, but can only afford N` | Default per-call max_tokens (32K) exceeds remaining OpenRouter balance | Lower the cap: `openclaw config set --batch-file` against `models.providers.openrouter.maxTokens` (and per-model). Restart gateway. The `openclaw.template.json` shipped here already has 4096/3072/6144/8192 caps — copy from there. |
| `openclaw.json` edits silently disappear after a gateway reload | Manual edits to top-level `models` block fail schema's required fields (`baseUrl`, `models[]`) and openclaw drops them on normalization | Use `openclaw config set --batch-file <file>` (canonical), not direct JSON edits. |
