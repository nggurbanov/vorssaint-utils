# T3 Code integration

This fork adds local and remote T3 Code environments to AI Agents in the Dynamic
Island. The integration targets T3 Code **0.1.0**, orchestration protocol **2**.
It uses the existing environment HTTP API; T3 itself does not need modification.

## T3 names in native usage

While AI Agents is enabled, the native usage reader also opens this Mac's
`~/.t3/userdata/statev2.sqlite` read-only. It selects project/conversation titles
and strong native session references from T3's projection tables. It does not
read auth tables, credentials or conversations. Matched sessions use the T3
conversation title in live activity and completion notices, and the T3 project
title in Projects, instead of a generated scratch-directory name.

The join uses provider plus native session ID, never a folder-name heuristic.
Ambiguous references are ignored. Project identity survives renaming, and names
are refreshed while the section runs. A missing/incompatible/busy T3 database
falls back to ordinary log names. Existing log records supply all cost/token
figures; no second copy is imported, and the usage archive keeps its original
names. Spending, model shares, trend buckets and the activity map keep their
existing accounting.

## T3 token-based usage

A separate thirty-second reader fetches changed thread projections through
`GET /api/orchestration/threads/:threadId` using the existing
`orchestration:read` credential. The thin decoder extracts billed
`turnTokenUsage`, native session/turn identities, run model selections and T3
project identity. It ignores context-window `tokenUsage`, messages, tool output,
files and conversation previews. No remote companion or additional permission
is needed. Usage requests do not block the live activity loop.

These counters feed the existing spending/API-value, model/project breakdown,
trend, activity and burn-rate cards. Costs use Vorssaint's model prices; cached
input and cache writes are removed from uncached input, and reasoning remains
inside output. Per-turn aggregates use base rates rather than guessing prompt
sizes or request premiums. They are estimates, not subscription charges. A turn
can cover several model responses, so it does not invent a response count.

Strong native provider/session/turn identities deduplicate repeated projections
and overlapping connections. Native logs take precedence for any session this
Mac already reads. Historical project names come from T3 project identity,
not a scratch-folder slug. Unknown model pricing stays unpriced. Missing or
invalid usage is excluded and marked incomplete, rather than replaced by zero
or by context-window counts. Unsupported providers are also marked incomplete.
The T3 heading explains these limits and shows a warning for missing/partial
counters or reads still pending.

Coverage is the T3 threads enumerated by the shell plus history observed during
this app run, within the existing 91-day window. T3's active HTTP shell does not
list older archived threads; they cannot be backfilled by this reader. Already
observed archived history is retained in memory while the connection runs.
Main-agent counters may omit provider-native subagents and are marked partial
when T3 reports them. Turn totals are dated by completion (or start while not
completed), so a turn spanning midnight is not split across days. Precise
native response logs remain preferable where available. Remote history is not
persisted to the usage archive and is cleared when the connection is removed,
authentication expires or the reader stops. Plan/account allowances continue to
come from their existing account readers.

T3 Connect account sign-in/discovery remains a separate authentication task.
A Connect HTTPS origin with direct read-only pairing can use the existing
endpoint field; no persistent SSH tunnel is required by this client.

References: T3 0.1.0 [turn token contract](https://github.com/pingdotgg/t3code/blob/v0.1.0/packages/contracts/src/providerRuntime.ts),
[thread HTTP reader](https://github.com/pingdotgg/t3code/blob/v0.1.0/apps/server/src/orchestration-v2/http.ts),
and [relay clients](https://github.com/pingdotgg/t3code/blob/v0.1.0/packages/contracts/src/relay.ts).

## Pair an environment

1. Enable Dynamic Island and its AI Agents section.
2. On the machine running T3, create a pairing grant:

   ```sh
   t3 auth pairing create --scope orchestration:read --ttl 5m --label Vorssaint
   ```

3. Open **Settings → Dynamic Island → AI Agents → T3 Code**. Enter the
   environment's origin (for example `https://dev.example.net`), paste its
   one-time pairing token, and choose **Connect environment**.
4. Pair each environment you want to follow. Re-pairing the same environment
   replaces its connection rather than duplicating threads.

HTTP is accepted only on loopback (`localhost`, `127.0.0.1`, or `::1`), including
an SSH forward you already manage. Remote origins require HTTPS. Redirects are
not followed. T3 Desktop's saved connections and T3 Connect sign-in are not
imported; this is a separate read-only client.

## Behavior

- The expanded AI page shows the thread title, project, environment, provider,
  model, state, and duration. Usage-limited threads retain the reset time when
  the provider supplies one. Plans awaiting review have a distinct state.
- The compact island shows T3 activity with priority for requests requiring
  attention. Waiting threads do not inflate the working count. Completion flashes
  briefly; configured completion notices honor the existing duration threshold.
- Native response logs keep their existing accounting. T3 per-turn usage adds
  estimates for sessions not already read locally; plan allowances stay separate.
- Environments are polled every three seconds. Failures back off to thirty
  seconds. Last-known activity expires ten seconds after the last successful
  read, so a dropped connection cannot leave an agent working indefinitely.
- Disabling AI Agents or stopping the island cancels polling. Sleep/session
  suspension clears activity and resumes through the existing island lifecycle.
- Authentication expiry requires re-pairing. Removing an environment deletes
  its local connection record and Keychain credential; server-side session
  revocation remains available in T3's access management.

## Data and credentials

Only `orchestration:read` grants are accepted. Access tokens are stored in the
app's device-only Keychain namespace, separate for Developer and official bundle
identities. Connection metadata is excluded from settings backups.

The shell response can include message previews, and thread projections can
include conversation text and tool output. These fields cross the wire because
T3 does not offer a counters-only projection. The thin decoders ignore them and
the integration does not persist prompts, responses, tool output or files. Thread titles and model/status
metadata stay in memory, while configured endpoint and environment labels stay
in preferences. Requests go directly to the endpoints the user pairs.

Before a credential is sent after reconnection, the public descriptor must still
identify the expected environment. Network and authentication failures do not
produce success notifications.

## Development and verification

Developer builds have separate preferences and a separate bundle identity, but
active system features can still overlap with an official app running alongside
them. Keep the Developer app closed while using the official app. For an
interactive test, first arrange a test window with the user and run only one
copy's island, shortcuts, input hooks and other global features at a time.


```sh
./build.sh --test-suite=agents
./build.sh --test-suite=notch
./build.sh --test-suite=preferences
./build.sh --dev
./build/VorssaintDeveloper --selftest
```

The test suite checks the released shell schema, waiting/plan/limit mapping,
completion transitions, environment isolation, read-only pairing, credential
routing, and deterministic stale-activity expiry. Fixture checks and a successful
build do not by themselves establish live UI acceptance.

Native results and the exact live-versus-fixture boundary are recorded in
[T3 acceptance](T3-ACCEPTANCE.md).

## Attribution

The initial activity model, transport, Keychain storage, polling/expiry logic,
localized pairing strings, and portions of the UI were adapted from
[Bruno Hjorth (liltaket)'s PR #2747](https://github.com/vorssaint/vorssaint-utils/pull/2747),
reference commit `d01e2144b9885fecd6a47c75ec07b14fee956e2d`, under GPL-3.0-or-later.
This branch starts at current upstream rather than merging that PR. It removes
unreleased legacy-settings migrations, adds 0.1.0 plan/usage-limit semantics,
keeps current Codex account support, and integrates the current island lifecycle.
