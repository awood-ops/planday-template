# plan-day — Microsoft To Do + Outlook automation for a personal daily briefing

PowerShell scripts that let an AI assistant (or you) manage Microsoft To Do tasks,
slot them into your Outlook calendar around real commitments, and keep the whole
thing running unattended every morning via Task Scheduler.

This is the **generic engine**. The personal layer — the skill/prompt file that
decides *what a good day looks like for you* — is deliberately not in this repo:
you write that part yourself.

## Security design

- **Public client + PKCE** — the correct OAuth flow for CLI tools. There is no
  client secret anywhere, because none is ever issued.
- **Single-tenant app registration** (`AzureADMyOrg`) — nobody outside your
  tenant can even start an auth flow against your app.
- **Refresh token encrypted with Windows DPAPI** (`CurrentUser` scope), stored in
  `%LOCALAPPDATA%\ClaudeGraph\` — useless on any other machine or account, and
  never inside a cloud-synced or git-tracked folder.
- **Access-token cache** — scripts share one cached access token instead of each
  rotating the refresh token, so parallel runs don't race.
- **Least-privilege scopes** — the default consent is
  `Tasks.ReadWrite Calendars.ReadWrite offline_access`, nothing more. Scopes for
  optional scripts (e.g. `Mail.Send` for `send-work-brief.ps1`) are opt-in at
  sign-in time, and the token refresh reuses exactly what was consented.
- The Client ID and Tenant ID in `config/graph-config.json` are not secrets, but
  the config directory is gitignored anyway so you can't leak anything by
  accident.

## Setup

1. **Register the app** (once, needs [Azure CLI](https://learn.microsoft.com/cli/azure/)):

   ```powershell
   pwsh -File scripts\setup-graph-app.ps1 -TenantId <your-tenant-guid>
   ```

   This creates a single-tenant public-client app named "Claude Code" with
   `Tasks.ReadWrite` delegated permission and a `http://localhost:8085` loopback
   redirect, then writes `config/graph-config.json`.

2. **Sign in** (once — opens a browser, catches the localhost callback):

   ```powershell
   pwsh -File scripts\authenticate-graph.ps1
   ```

   Requests `Tasks.ReadWrite Calendars.ReadWrite offline_access` by default —
   the minimum the core task/calendar scripts need — and stores the
   DPAPI-encrypted refresh token. Everything after this runs silently.

   Optional scripts need extra scopes; pass them explicitly when you opt in.
   `send-work-brief.ps1` is the only one: it needs `Mail.Send`.

   ```powershell
   pwsh -File scripts\authenticate-graph.ps1 -Scopes "Tasks.ReadWrite Calendars.ReadWrite Mail.Send offline_access"
   ```

   Re-running the script replaces the stored token and its consented scopes,
   so you can widen (or narrow) at any time.

3. **Configure** — copy each `config/*.example.json` to the same name without
   `.example` and fill it in. Only `graph-config.json` is required (step 1
   creates it); the others enable optional scripts.

4. **Schedule** (optional):

   ```powershell
   pwsh -File scripts\register-daily-sync.ps1
   ```

   Registers a Task Scheduler job that runs the full pipeline every morning.

## Scripts

| Script | Purpose |
|---|---|
| `setup-graph-app.ps1` | One-time app registration via Azure CLI |
| `authenticate-graph.ps1` | One-time interactive sign-in (auth code + PKCE) |
| `get-graph-token.ps1` | Returns a valid access token; the single auth path all other scripts call |
| `create-todo.ps1` / `update-todo.ps1` | Create / update To Do tasks (due date, reminder, importance, recurrence, complete) |
| `get-todo.ps1` | Fetch incomplete tasks, write a daily markdown plan |
| `get-week-tasks.ps1` | Same, for a 7-day window |
| `sync-tasks-to-calendar.ps1` | Slot tasks due today into the calendar as "PlanDay" events, around blocked time; rolls unfinished tasks forward; skips check-email-type tasks |
| `clear-planday-events.ps1` | Remove all PlanDay events for a date |
| `sync-birthdays.ps1` | Calendar birthdays (+ Father's/Mother's Day) → reminder tasks 1 week ahead |
| `get-bin-schedule.ps1` / `sync-bins-to-calendar.ps1` | Bin collection dates → morning-reminder tasks (York Council API — see [Adapting the bin scripts to your council](#adapting-the-bin-scripts-to-your-council)) |
| `daily-sync.ps1` | End-to-end morning pipeline: birthdays → tasks → work-calendar blocked slots → calendar sync |
| `send-work-brief.ps1` | Email a structured day plan to another address (e.g. your work account) |
| `register-daily-sync.ps1` | Task Scheduler registration for `daily-sync.ps1` |

## Adapting the bin scripts to your council

`get-bin-schedule.ps1` is the only location-specific script in the repo — it
calls York Council's waste API. Everything downstream (`sync-bins-to-calendar.ps1`,
the daily pipeline) only cares about its output contract: a JSON array of
upcoming collections, each shaped like this:

```json
[
  {
    "service": "RECYCLING",
    "date": "2026-07-09",
    "dayOfWeek": "Thursday",
    "description": "55L BLACK RECYCLING BOX x3"
  }
]
```

To point it at your own council:

1. **Find your data source.** Many UK councils expose a public waste API keyed
   on UPRN — your property's Unique Property Reference Number, which you can
   look up at [findmyaddress.co.uk](https://www.findmyaddress.co.uk/). Open your
   council's "check your bin day" page with the browser dev tools Network tab
   and you'll often find a JSON endpoint you can call directly. No API? Some
   councils publish an iCal feed instead, which parses just as easily.
2. **Rewrite the fetch** in `get-bin-schedule.ps1` to call your source, keeping
   the output shape above: `service` is the machine key, `description` is the
   human label, and `date` must be `yyyy-MM-dd`.
3. **Update the label map** in `sync-bins-to-calendar.ps1` — the `switch` that
   turns `REFUSE` / `RECYCLING` / `GARDEN` into "Grey bin" / "Recycling box" /
   "Garden bin" should match whatever `service` values your source returns.
   Unknown values fall through and are used as-is, so this step is cosmetic.
4. **Drop the York quirk.** The block commented "If nextCollection is exactly 14
   days out" works around York's API flipping past today's collection on the
   morning it happens. Your council's API probably doesn't need it.

The pattern isn't really about bins. Anything that emits
`service`/`date`/`description` — an allotment watering rota, a school menu, a
gym timetable — gets turned into a 07:00-reminder task by the same sync script.

## Notes

- Windows-only: token encryption uses DPAPI and scheduling uses Task Scheduler.
- Graph returns event times in UTC; scripts pass your local timezone via the
  `Prefer: outlook.timezone` header where it matters.
