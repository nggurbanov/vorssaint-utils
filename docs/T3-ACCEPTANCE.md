# T3 integration acceptance — 17 October 2026

## T3 Connect sign-in and discovery

The native Settings section now starts a separate production OAuth device
authorization and displays T3's verification link with an optional browser
button. The initial auto-opening flow's code and cancellation controls were
visibly checked on the Mac below; automatic opening was then removed at the
user's request, with selectable and copyable link controls. Account approval is still
pending: production machine discovery, relay bootstrap and restoration of a
real Connect account have **not yet** been accepted end to end.

The production Swift DPoP client separately passed **7 live checks** against
dev-01 over a temporary SSH forward: proof-bound environment token exchange,
Keychain round-trip, 38 shell threads and 19 usable per-turn records. The owned
session was explicitly revoked, zero matching active sessions remained, and the
SSH forward was closed. No account login or agent was launched by this test.

Fixtures cover the complete account/machine handoff, proof signatures and token
hashes, scope and identity binding, fresh proofs on activity/usage reads,
rejection of bearer downgrade, account restoration, renewal without duplicate
connections, cancellation followed by late OAuth success, sign-out preserving
manual connections, and prevention of login restoration after failed Keychain
deletion. This uses T3's public CLI OAuth identifier and web relay protocol;
it is an independent compatibility client, not an officially registered client.

Updated checks: **1,138 agents**, **66,098 notch**, **111 preferences** and
**314 repository** checks passed. The native Developer build and selftest passed. As above,
fixtures and direct environment acceptance do not establish the pending real
Connect-account path.

## Token usage and T3 names follow-up

Verified the real read-only HTTP thread projection on dev-01: a sampled Codex
conversation supplied 19 provider turns and 19 usable billed-token records.
The native Swift client passed 7 live acceptance checks, including Keychain
round-trip, shell decoding, per-turn decoding, project titles and native IDs.
No additional scope, remote companion or T3 source changes were needed.

On the same Mac and notch layout described below, paired a temporary local
gateway forwarding real dev-01 descriptor, OAuth, shell and full thread reads.
The gateway substituted privately held bootstrap tokens for a harmless UI marker;
no actual credentials were typed into the automation transcript. This used real
remote token data, not lifecycle fixtures. The native island visibly populated
spending/API-value, model/project breakdowns, trends and activity history.
Changed the period to 30 days and verified the remote project titles and history;
unknown pricing displayed a lower-bound API value and token-based breakdowns.
Local live sessions visibly used T3 conversation titles instead of scratch slugs.

Restored the reporting period to Today, removed the test connection through
Settings, verified an empty Developer T3 Keychain namespace, revoked both owned
environment sessions and verified zero remain active. Closed both temporary
ports and removed owned bootstrap/gateway files. No agent was launched and no
existing T3 thread or project was modified.

Unit/contract checks cover disjoint cache accounting, reasoning tokens, pricing,
native-log precedence, repeated-turn deduplication, source/provider isolation,
project attribution and renaming, missing/invalid counters and the actual
production completion-notice reader. Native build and selftest passed. The
archive/subagent/midnight limitations in [T3 integration](T3-INTEGRATION.md)
remain explicit; this is not complete transcript-level billing history.

Test host: Apple Silicon Mac `Mac16,12`, macOS **27.0.1**. Native developer
build, real notch layout; official Vorssaint was closed before testing and was
not replaced. The Developer app uses `com.vorssaint.utils.dev`.

## Live and controlled data

The native settings flow paired a read-only T3 **0.1.0 / protocol 2** environment
on `dev-01`. A temporary, loopback-only gateway forwarded the real descriptor,
OAuth exchange and thread-summary reads through an owned SSH tunnel. It
substituted a test marker for the private bootstrap credential so credentials
were never printed or entered into tool transcripts. The real feed was connected;
there were no active remote turns during that check. The preceding direct
production-client acceptance decoded 38 real remote threads.

Lifecycle scenarios below used controlled shell snapshots through that same
local gateway. They exercise the actual production client, persistence and SwiftUI
views, but are **not claims that real remote agents entered those states**. No
agent tasks were launched and no existing T3 threads were changed.

## Observed native behavior

- Pairing completes in Settings → Dynamic Island → Content → AI Agents → T3 Code.
  The pairing field clears, the environment is listed and the state is Connected.
- The saved connection resumes after an app restart using its Keychain grant.
- A working remote fixture shows `T3 · 1` in the compact island. Its expanded row
  shows title, environment, provider/model, elapsed time and working state.
- Input requests show an orange `T3 · ?`; approval requests show their approval
  marker/label. Actionable plans show the plan-review marker and label.
- Usage-limited work shows the limit state and the reported reset time.
- Completion shows a green `T3 · ✓`. The controlled completion frame was held
  long enough to inspect, then released; the strip returned to ordinary local
  activity after its normal five-second expiry.
- An HTTP 503 makes the connection Reconnecting. Its last remote activity clears
  after the ten-second freshness window, and is no longer shown as working.
- Recovery resumes polling and returns to Connected without re-pairing.
- An HTTP 401 clears activity and asks to pair again to restore read access.
- Removing the temporary connection returns the settings to Not connected.

## Findings fixed during acceptance

A real local Codex completion notice covered a pending remote question. A
regression test now executes the production island delivery method against
remote input/approval/plan fixtures: completion notices are suppressed while those
requests need attention, while budget alerts and ordinary completions still work.
The regression failed before the fix and passed afterward.

The narrow settings connection row wrapped its label and endpoint around the two
action buttons. Its metadata now has the full row width, with actions below.
Compact T3 text now uses the same state color as its marker, rather than inheriting
a local provider's tint. Transient 429/5xx responses report endpoint unavailability
instead of an unexpected payload.

## Automated validation

- Agents: **1,034 checks passed**, including the new notice regression and HTTP
  authentication/permission/unavailability boundaries.
- Notch: **66,098 checks passed**.
- Preferences: **111 checks passed**.
- Developer build: passed with stable local signing.
- Developer selftest: `SELFTEST OK`.

Automated geometry coverage includes the capsule paths, but this native acceptance
used the Mac's notch. Lock Screen presentation, permission prompts, multiple
physical displays and long sleep/wake cycles were not exercised.

## Cleanup and remaining setup

The temporary connection and its Keychain item were removed. Both owned
acceptance sessions on `dev-01` were explicitly revoked: the short pairing-code
TTL does not shorten T3's default 30-day access-session lifetime. Temporary
bootstrap files, gateway and SSH tunnel were removed/stopped.

The Developer app remains running, with the official app closed. There is no
persistent remote environment configured by this test; daily use needs a normal
read-only pairing to a stable endpoint or an SSH forward the user manages. See
[T3 integration](T3-INTEGRATION.md).
