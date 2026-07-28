# Research: Remove the Dead Ledger-State Emitter

## R-001: Dead-code claim reverified

**Decision**: Treat the executable as dead and remove it end-to-end.

**Evidence**: An exact-name audit at base commit `c60cb42` found 45 live
matches across 18 files. In `scripts/`, the only matches are two adjacent
comment lines in `scripts/bootstrap-producer.sh`; no executable statement calls
the tool. The producer instead invokes `amaru snapshot create` and
`amaru node bootstrap`.

**Rationale**: This independently reconfirms the issue's premise after the
latest sibling merge, satisfying the epic's evidence-over-assumption rule.

**Alternatives considered**:

- Keep a standalone app: rejected because it has no supported caller and
  remains misleading build/image surface.
- Deprecate without removal: rejected because the tool is already outside the
  production path and the ticket explicitly owns removal.

## R-002: Preserve history, remove live references

**Decision**: Report exact-name matches in two buckets.

**Live bucket (must be empty)**: `app/`, `lib/`, `scripts/`, `nix/`, `tests/`,
`flake.nix`, `justfile`, `.github/`, `amaru-bootstrap.cabal`, `README.md`,
`AGENTS.md`, current-facing `docs/`, and `skills/`.

**Process/history bucket (expected matches)**:

- `specs/001-*`, `specs/003-*`, and `specs/004-*`: historical feature records;
- `specs/050-*`: the actionable process contract for this removal;
- `docs/history/`: project history;
- the constitution and amendment log: governance history.

**Rationale**: A-003 ruled that obscuring exact names in the current tasks
would game the audit, while A-001 ruled that rewriting historical claims would
falsify them.

## R-003: Byte identity is measured on the generated bundle

**Decision**: Compare the recursive NAR hash of the internal synthesized
`testnet_42` bundle before and after the removal.

**Baseline**:

- Recursive NAR hash:
  `sha256-hIvI4FyFRdDcd6WJjuhjNjryLGens90TRENhz2eCL90=`
- Regular files: 49
- Apparent bytes: 194,485

**Method**: Evaluate the
`checks.x86_64-linux.bootstrap-producer-synthesized` derivation, locate its
`bootstrap-producer-synthesized-bundle` input derivation, realize it, and hash
the `testnet_42` output subtree with `nix hash path`.

**Rationale**: The public synthesized check validates layout but produces an
empty success marker. Hashing its internal generated bundle measures the
actual ledger/chain/snapshot bytes rather than merely re-running a structural
assertion.

## R-004: Preserve sibling mock honesty

**Decision**: Base this ticket on merged PR #56 and delete only the obsolete
mock block from `tests/test-bootstrap-producer-canonical-cli.bats`.

**Evidence**: The merged mock-surface declarations contain arrays for Amaru
and `header-extractor` only; there is no emitter array entry to remove.
`checks.x86_64-linux.cli-mock-honesty` is now a required focused proof.

**Rationale**: This consumes the sibling release without weakening or
restructuring its fail-closed guard or its added `nix/checks.nix` check.

## R-005: Inspect image layers directly

**Decision**: Build the producer image without a result link, unpack its Docker
archive into a temporary directory, and list every `layer.tar`.

**Pre-change evidence**: The image contains both
`./bin/ledger-state-emitter` and the executable's Nix-store path.

**Acceptance**: The same layer scan after removal must find zero paths ending
in `/bin/ledger-state-emitter`.

**Rationale**: A successful image derivation alone proves buildability, not
absence of a dead binary.
