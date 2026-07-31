# Quickstart: Daily Validated Amaru Image Handoff

## Local contract path

1. Run the focused daily-handoff flake check.
2. Run the unchanged fixture and confirm one canonical `UNCHANGED` result.
3. Run the changed fixture and confirm the exact observed SHA is the only pin
   mutation and a strict handoff appears only after CI/publication evidence.
4. Run wrong-origin, missing-CI, missing-publication, and missing-digest
   fixtures and confirm each exits nonzero with no handoff.
5. Seed the mock-only CLI drift through the ticket gate, capture the nonzero
   Build Gate result, restore exact bytes, and rerun green.

## Hosted pull-request path

1. The pull request executes the same state machine with the injected fixture
   transport and cannot mint production releases or mutate pins.
2. After local acceptance, apply the explicit App-probe label.
3. The workflow mints a repository-scoped App token, creates one recorded
   disposable probe branch/PR from main, waits until `Build Gate` is observed,
   verifies the main rules endpoint still requires pull requests and
   `Build Gate`, then closes the probe PR and deletes its exact branch.
4. Remove the probe label after its hosted evidence is captured.

## Production path after merge

The scheduled and manual triggers call the same implementation. An unchanged
source tuple publishes a day-keyed `UNCHANGED` result. A changed tuple creates
an exact-pin PR, waits for required integration and final-main CI, waits for
the SHA-tagged image publication receipt and registry digest, then publishes
the tuple-keyed handoff and a day-keyed result. Any missing or conflicting
state exits nonzero without a success handoff.
