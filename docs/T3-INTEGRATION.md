# T3 Code activity

This fork adds local and remote T3 Code environments to AI Agents in the Dynamic
Island. The integration targets T3 Code **0.1.0**, orchestration protocol **2**.
It uses the existing environment HTTP API; T3 itself does not need modification.

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
- Local CLI usage cards keep their existing accounting. Remote T3 activity is
  not added to their token totals, plan allowances, or API-value estimates.
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

The shell response includes thread/project metadata and can also contain a latest
message preview. The decoder ignores that preview; the integration does not
persist prompts, responses, tool output, or files. Thread titles and model/status
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
