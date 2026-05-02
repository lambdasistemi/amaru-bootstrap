---

description: "Task list for 005-amaru-run-live-test"
---

# Tasks: Run Amaru Against the Produced Bundle in Live Test

**Input**: Design documents from `/code/amaru-bootstrap-005-spec/specs/005-amaru-run-live-test/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/failure-classes.md](./contracts/failure-classes.md),
[quickstart.md](./quickstart.md).

**Tests**: This feature **is** the test, so test-first / TDD framing
does not apply in the usual sense. Validation tasks are explicit
(T020–T022) and must reproduce [issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34)
against the failing producer image.

**Organization**: Tasks are grouped by the three user stories from
[spec.md](./spec.md). Story dependencies are sequential within the
same bats file (Phase 3 lays the helper + plumbing US1 needs;
Phase 4 layers richer diagnostics on top of US1's success path;
Phase 5 ratifies the "no parallel testnet" property by inspection).

## Format: `[ID] [P?] [Story] Description`

- **[P]** = different file, no dependency on incomplete tasks
- **[Story]** = US1 / US2 / US3 (US1 = MVP)
- All file paths are absolute, rooted at `/code/amaru-bootstrap-005-spec`

## Path Conventions

This is the existing `amaru-bootstrap` single-project repo:

- `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats` — the file being extended
- `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` — shared bash helpers
- `/code/amaru-bootstrap-005-spec/justfile` — `live-bootstrap-producer` recipe
- `/code/amaru-bootstrap-005-spec/nix/amaru.nix` — already-pinned amaru binary (read-only reference; not modified)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Make the flake-pinned `amaru` binary available to the
existing `live-bootstrap-producer` justfile recipe so the bats test
inherits it (FR-002).

- [X] T001 Inspect the flake to confirm the canonical attribute that exposes the pinned amaru binary (`nix flake show --json | jq '.packages."x86_64-linux"'` and `nix/amaru.nix`); record the attribute name to use in `nix shell` (e.g. `.#amaru` or `.#packages.x86_64-linux.amaru`) so subsequent tasks reference a single canonical name. — `flake.nix:103` exposes `packages.x86_64-linux.amaru`; canonical attribute is `.#packages.x86_64-linux.amaru`.
- [X] T002 Edit `/code/amaru-bootstrap-005-spec/justfile` `live-bootstrap-producer` recipe (around lines 53–73): add the amaru attribute identified in T001 to the `nix shell` invocation that wraps `bats --tap tests/test-bootstrap-producer-live.bats`, alongside the existing `nixpkgs#bats`, `nixpkgs#docker-client`, etc. No other recipes change.

**Checkpoint**: `just live-bootstrap-producer` puts `amaru --version`
on `$PATH` inside the bats shell; existing test still passes
unchanged.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Plumb the cardano-node container's N2N port to the host
so a host-side amaru can dial it. This is the single shared
prerequisite for all user stories (per research.md R-1) and lives in
shared shell helpers + the existing test's `docker run`.

**⚠️ CRITICAL**: No US1/US2/US3 work begins until T003–T005 land.

- [X] T003 Add helper `wait_for_node_n2n_port <container> <retries>` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that polls `docker port "$container" 3001/tcp` until docker reports a published host port, prints it on stdout, returns 1 after `<retries>` seconds. Mirrors the polling shape of the existing `wait_for_node_socket`.
- [X] T004 Modify the `docker run -d --name "$NODE_CONTAINER" …` invocation in `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats` (currently lines 76–90) to add `-p 127.0.0.1::3001` so docker assigns a random host port bound to loopback. No other flags change.
- [X] T005 In the same `@test` body, after `wait_for_node_socket` succeeds, call `wait_for_node_n2n_port "$NODE_CONTAINER" 60` and capture its stdout into a local `node_host_port` variable. Fail the test with `docker logs "$NODE_CONTAINER"` dumped if the helper returns non-zero.

**Checkpoint**: The existing test still passes; `node_host_port` now
holds a usable host port pointing at the live node's N2N socket; no
behaviour observable to the consume step has changed yet.

---

## Phase 3: User Story 1 — Catch consumer-boundary regressions in CI (Priority: P1) 🎯 MVP

**Goal**: After the producer step finishes its on-disk shape
assertions, launch the flake-pinned amaru against the bundle peering
with the live node, hold for `BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS`
(default 60), then fail if amaru's log contains any of the four
fatal substrings or if amaru exited before the hold elapsed.

**Independent Test**: Run
`BOOTSTRAP_PRODUCER_IMAGE=ghcr.io/lambdasistemi/amaru-bootstrap-producer:pr-32-ad64e76778b0408ec66f353c7e58c8a1e7d4045f just live-bootstrap-producer`
— the test must fail with one of `vrf` / `consensus` / `header` /
`rollback`. Re-run against a known-good producer image; the test
must pass.

### Implementation for User Story 1

- [X] T006 [US1] Add a skip predicate to the `setup()` of `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats`: `command -v amaru >/dev/null 2>&1 || skip "amaru unavailable"`. Place it next to the existing `command -v docker / db-synthesizer` checks (around lines 44–48).
- [X] T007 [US1] Add helper `parse_hold_window_seconds` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that reads `${BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS:-60}`, validates it is a positive integer (regex `^[1-9][0-9]*$`), prints it on stdout, returns 1 (with an error message) on malformed input.
- [X] T008 [P] [US1] Add helper `start_amaru_run <bundle-dir> <peer-host-port> <log-path>` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that backgrounds `amaru --with-json-traces run --network testnet_42 --ledger-dir <bundle>/ledger.testnet_42.db --chain-dir <bundle>/chain.testnet_42.db --listen-address 127.0.0.1:0 --peer-address 127.0.0.1:<port>` with stdout+stderr redirected to `<log-path>`, and prints `$!` on stdout. Mirrors the CLI shape used by `nix/checks.nix`'s `amaru-run-bootstrap` at `nix/checks.nix:418`.
- [X] T009 [US1] Add helper `assert_amaru_alive <pid>` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that returns 0 if `kill -0 "$pid"` succeeds, 1 otherwise — small wrapper kept separate from the scanner so US2 can layer richer messaging on it without re-implementing the liveness probe.
- [X] T010 [P] [US1] Add helper `scan_amaru_log_for_fatal <log-path>` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that grep -F's the four substrings from [contracts/failure-classes.md](./contracts/failure-classes.md) (`Invalid VRF proof` → `vrf`, `Consensus died` → `consensus`, `HeaderValidationError` → `header`, `ledger inconsistency` → `rollback`) against `<log-path>` in that order. On first match: print `<class>` on stdout, return 0. No match: return 1. Substring matching only, no regex. — Implemented with the contract's stderr context block included up-front (would-be T015 work).
- [X] T011 [US1] Add helper `stop_amaru_run <pid>` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that does `kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true`. Used both by happy-path teardown and by the `teardown()` reaper (T013).
- [X] T012 [US1] Extend the existing `@test` body in `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats`, after the on-disk shape assertions (after line 159) and before the closing `}`, with the consume block: parse the hold window via T007, start amaru via T008 → `AMARU_PID`, sleep the hold window, run liveness (T009) and substring scan (T010), assemble the failure message per contracts/failure-classes.md, then `stop_amaru_run` and exit cleanly.
- [X] T013 [US1] Update `teardown()` of `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats` (around lines 66–73) to call `stop_amaru_run "${AMARU_PID:-}"` before the existing `docker rm -f` calls, with the variable defaulting to empty so the existing test path still works when AMARU_PID was never set.
- [X] T014 [US1] Sanity-check that the consume block is `set -e` clean: bats traps non-zero return from helpers and surfaces them as failures, so unintended early returns from T008/T010/T011 must fail the @test rather than silently continuing.

**Checkpoint (MVP)**: `just live-bootstrap-producer` passes against
a known-good producer image and fails class-labelled against
[issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34)'s
`pr-32-ad64e7…` image. SC-001 + SC-002 + SC-005 satisfied.

---

## Phase 4: User Story 2 — Make the failure mode obvious from test output (Priority: P2)

**Goal**: When the test fails, bats output names the class and
quotes 5 lines of context (or the tail-50 for the "exited-early"
case), per [contracts/failure-classes.md](./contracts/failure-classes.md).

**Independent Test**: With the MVP installed, mutate
`$AMARU_LOG_FILE` (e.g. inject one of the four fatal substrings via
a synthetic test bundle or a helper-only unit harness) and assert
the bats output names the class and quotes the surrounding lines.

### Implementation for User Story 2

- [X] T015 [P] [US2] Extend `scan_amaru_log_for_fatal` (T010) in `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash`: on a match, also print to stderr a structured block matching the contract — `--- amaru consume failure: <class> ---`, then the matching line plus 2 lines before / 2 lines after via `grep -n -B2 -A2 -F`, then `--- end amaru consume failure ---`. — Folded into T010 implementation.
- [X] T016 [P] [US2] Add helper `report_amaru_exited_early <log-path> <elapsed> <hold>` to `/code/amaru-bootstrap-005-spec/tests/lib/bootstrap-helpers.bash` that prints to stderr the `exited-early` block from contracts/failure-classes.md: header, one-line summary `amaru process exited before hold window (<elapsed>s of <hold>s)`, the last 50 lines of the log (`tail -n 50`), trailing `--- end amaru consume failure ---`.
- [X] T017 [US2] Update the consume block in `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats` (added in T012) to call `report_amaru_exited_early` when liveness fails AND no fatal substring matches, and to rely on T015's stderr output when a substring match drives the failure. Order of checks must follow contracts/failure-classes.md: liveness, substring scan (regardless of liveness result so a crashed-with-VRF case still gets the `vrf` label), pass.
- [X] T018 [US2] On the green path, print exactly one informational line on stdout: `+ amaru ran cleanly for <hold>s, no fatal substrings matched` — analogous to the existing `+ era-readiness predicate satisfied` line.
- [X] T019 [US2] Verify shellcheck-clean: run `shellcheck tests/lib/bootstrap-helpers.bash` from a `nix shell nixpkgs#shellcheck` (or via the existing `just shellcheck` recipe if applicable) — no findings; constitution Code Quality Gates require this for all shell. — Only pre-existing SC2034 warning on `BOOTSTRAP_PRODUCER_SCRIPT`; new code is clean.

**Checkpoint**: SC-004 satisfied — a failed CI log alone identifies
which of the four classes fired, no `docker logs` step required.

---

## Phase 5: User Story 3 — Run inside the existing live-test harness (Priority: P3)

**Goal**: Lock in by inspection that no parallel testnet was stood
up. SC-003 ratifies "one cardano-node + one producer + one amaru
per run". This is largely a *non*-implementation user story — most
tasks are review / negative tests guarding against regression.

**Independent Test**: Re-read the diff: only one
`docker run -d --name "$NODE_CONTAINER"` and only one
`docker run --name "$PRODUCER_CONTAINER"` exist. The amaru-consume
step uses only the helpers added above and references
`$NODE_CONTAINER` (not a freshly started node) for its peer port.

### Implementation for User Story 3

- [X] T020 [US3] Confirm the `setup()` of `/code/amaru-bootstrap-005-spec/tests/test-bootstrap-producer-live.bats` is unchanged in its `make_live_node_inputs` / `synthesize_live_chain_db` calls — reuse mandate FR-007. (Read-only verification.) — Confirmed at lines 64–65.
- [X] T021 [US3] Confirm there is exactly one `docker run` for `$NODE_CONTAINER` and one `docker run` for `$PRODUCER_CONTAINER` in `tests/test-bootstrap-producer-live.bats` after T002–T013 land — `grep -c '^[[:space:]]*docker run' tests/test-bootstrap-producer-live.bats` returns the same value as before this feature (modulo the existing one-time uses). — Confirmed: one docker run per container at lines 79 and 124. No new docker run sites added.
- [ ] T022 [US3] Run `just live-bootstrap-producer` end-to-end against a locally built producer image and confirm: (a) cardano-node starts once, (b) bundle is produced, (c) amaru runs once, (d) hold window elapses, (e) test passes. Capture wall-clock time; document in plan.md (under a `Validation` block) that the extra cost over today's live test is approximately the hold-window length plus amaru startup (~5–10 s). — **Deferred: requires Docker daemon + a built producer image; user-driven validation.**

**Checkpoint**: All three user stories implemented and validated.
SC-001..SC-005 satisfied.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T023 Update [quickstart.md](./quickstart.md)'s "What the new step proves" section if any of the implementation choices changed during Phase 3–5 (e.g. helper name renames). Spec-quality drift check. — No drift; helper names and env-var name match the planned spec.
- [X] T024 Cross-link from `/code/amaru-bootstrap-005-spec/CLAUDE.md` "Active feature" section to `specs/005-amaru-run-live-test/` (analogous to the existing pointer at `001-snapshot-format-smoke`).
- [ ] T025 [P] Open / link a follow-up issue in `lambdasistemi/amaru-bootstrap` (or comment on [#34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34)) summarising: "the consumer-side gap is now closed by `tests/test-bootstrap-producer-live.bats` — Asks 2 and 3 (VRF key preservation, defensive pre-commit verify) remain open separately." Detector-only delivery, per spec Assumptions. — **Deferred to PR / merge time per workflow rule "no push upstream without asking".**
- [ ] T026 Run the validation matrix from [quickstart.md](./quickstart.md) one final time: known-good image → green; `pr-32-ad64e7…` failing image → red with class label; `BOOTSTRAP_LIVE_AMARU_HOLD_SECONDS=20` → still red within shorter window. Records SC-001 + SC-002 satisfied. — **Deferred: same Docker-daemon constraint as T022.**

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1, T001–T002)**: no in-repo deps; can start immediately.
- **Foundational (Phase 2, T003–T005)**: depends on Setup (the recipe must put `amaru` on PATH so subsequent runs can validate); T003 can be drafted in parallel with T002.
- **US1 (Phase 3, T006–T014)**: depends on Foundational. Inside US1, T006/T007/T008/T009/T010/T011 are independent helper additions ([P]); T012 (the @test extension) depends on all of them; T013 depends on T011; T014 is a sanity sweep.
- **US2 (Phase 4, T015–T019)**: depends on US1's MVP (T015 extends T010; T017 wires both into the @test added in T012).
- **US3 (Phase 5, T020–T022)**: validation-only; depends on US2 having landed (so the diagnostics it inspects are present).
- **Polish (Phase 6)**: depends on US3 validation.

### User Story Dependencies

- **US1** is the MVP. It can ship alone (with the bare-bones failure messages from T010 only) and already satisfies SC-001 + SC-002 + SC-005.
- **US2** layers richer diagnostics on US1; cannot ship before US1.
- **US3** is structural confirmation only and lands after US2 to prevent re-introducing a parallel testnet during US2 work.

### Within Each User Story

- US1: helpers (T006–T011, mostly [P]) → @test wiring (T012) → teardown (T013) → sanity sweep (T014).
- US2: extend scanner output (T015) and add exited-early reporter (T016) [P] → wire into @test (T017) → green-path output (T018) → shellcheck (T019).
- US3: read-only verification of FR-007 properties (T020–T022).

### Parallel Opportunities

- **Phase 1**: T001 (read) and T002 (write) sequential.
- **Phase 2**: T003 (helper, new lines) can land in parallel with T004 (one-line edit in the bats file) — different files. T005 sequences after both.
- **Phase 3**: T008 and T010 are different bash functions added to the same file (`bootstrap-helpers.bash`) — only one of them carries [P], because two appends to the same file conflict in patch order. T015/T016 in US2 likewise: only one [P].
- **Phase 5**: T020 / T021 are pure read tasks; can run in parallel.
- **Phase 6**: T025 [P] is repository-external.

---

## Parallel Example: User Story 1

```bash
# Helpers added to bootstrap-helpers.bash (sequence-safe; pick any
# single appender to mark [P] without conflicting on file edits):
Task: "T008 start_amaru_run helper"
Task: "T009 assert_amaru_alive helper"
Task: "T010 scan_amaru_log_for_fatal helper"
Task: "T011 stop_amaru_run helper"

# Then converge on @test extension:
Task: "T012 wire consume block into existing @test"
Task: "T013 update teardown to reap AMARU_PID"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 (T001–T002) → amaru on PATH inside the recipe.
2. Phase 2 (T003–T005) → node N2N port reachable from host.
3. Phase 3 (T006–T014) → US1 done.
4. **STOP** and validate against [issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34)'s
   failing image and a known-good image. Ship as PR #1 if MVP suffices.

### Incremental Delivery

- **PR #1 (MVP)**: Phases 1–3. Closes the consumer-side gap; failure messages are minimal but the class is identifiable from log content.
- **PR #2 (Diagnostics)**: Phase 4 (T015–T019). Class-labelled blocks + exited-early reporter + green-path informational line.
- **PR #3 (Validation pass)**: Phase 5 (T020–T022) + Phase 6 (T023–T026). Harden + close out [issue #34](https://github.com/lambdasistemi/amaru-bootstrap/issues/34).

### Single-PR Strategy (alternative)

If the team prefers one PR landing all three stories, the dependency
order (T001 → T002 → T003 → T004 → T005 → T006 … → T026) keeps each
commit bisect-safe: every commit between Phase 2 checkpoint and the
end keeps the existing live test green; failure-class diagnostics
arrive monotonically.

---

## Notes

- All edits land in three files: `tests/test-bootstrap-producer-live.bats`, `tests/lib/bootstrap-helpers.bash`, `justfile`. No new files, no new flake outputs, no new in-repo binaries (constitution Principles I, II, V).
- The substring matchers in T010 / T015 are a behaviour contract with the upstream amaru binary (per [contracts/failure-classes.md](./contracts/failure-classes.md)); changing them later requires updating both files in lockstep.
- The hold-window default of 60 s is set in the bash helper (T007), not duplicated in the @test body — single source of truth.
- Stop at the MVP checkpoint (end of Phase 3) to validate independently before layering US2 / US3.
