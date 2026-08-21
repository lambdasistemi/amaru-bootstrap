# Specification: carried era-history bootstrap patch

Issue: `lambdasistemi/amaru-bootstrap#95`

Artifact ceiling: 110 lines.

## Outcome

The SHA-pinned Amaru `node bootstrap` accepts the producer's already-derived
custom-network era history through the same `--era-history` /
`AMARU_ERA_HISTORY` input shape as `node run`, so the exact PR 93 fixture
builds a complete ledger/chain bundle and its live producer succeeds.

## Registry amendment (verbatim binding)

- Amaru source identity remains the exact bare upstream commit SHA; the patch hash and upstream base SHA are part of build identity.
- No fork, hidden source substitution, blessed-network relabeling, local bootstrap reimplementation, or fixture weakening.
- Retirement is executable, not prose: the first upstream commit supplying an equivalent bootstrap input that passes the unchanged fixture must, in its accepting pin bump, remove the patch, prove the resulting source identity, and rerun the same boundary checks.

## Requirements

- **R-095-01 — joined build identity:** The Amaru package MUST apply one
  repository-versioned patch only to upstream
  `ba992f651d3b5e2b49f12d461b86ab8f7a55f994`; the full upstream SHA and
  declared SHA-256 of the exact patch bytes MUST jointly identify the build.
- **R-095-02 — bootstrap input:** The patch MUST expose custom-network era
  history on `node bootstrap` with the existing `node run` flag/environment
  names and thread the loaded value into full bootstrap snapshot epoch
  mapping. The producer MUST pass its staged, already-validated bundle file.
- **R-095-03 — CLI reconciliation:** Strict success-capable mocks and the real
  CLI reconciliation MUST cover the new input without accepting unrelated or
  legacy command surfaces.
- **R-095-04 — fail closed:** Missing or malformed custom-network history and
  a history whose epoch mapping is inconsistent with the requested fixture
  MUST fail before a complete store is committed, preserving the true cause.
  Each negative control MUST be demonstrated able to fail.
- **R-095-05 — fixture integrity:** The `flake.lock` and peer-resolution blobs
  from PR 93 head `b52ca563` MUST be exact. Every other changed path is the
  candidate integration delta; no unrelated fixture or acceptance weakening
  is permitted.
- **R-095-06 — full live proof:** Hosted Build Gate and Live Bootstrap Producer
  MUST be fully green on the exact accepted head and exercise the complete PR
  93 fixture through Amaru startup.
- **R-095-07 — independent acceptance:** A fresh independent audit MUST cover
  the complete candidate and all required hosted contexts MUST be green on the
  exact accepted head.
- **R-095-08 — executable retirement:** A permanent check MUST fail a source
  pin/patch identity mismatch and name removal of the patch plus rerunning the
  unchanged boundary when upstream supplies the equivalent interface.

## Invariants

- **I-095-IDENTITY (BLOCKING):** The built Amaru source is the declared bare
  upstream SHA plus exactly the declared patch bytes; neither identity may
  drift independently.
- **I-095-INPUT (BLOCKING):** The custom-network era history loaded at the CLI
  is the value used by `bootstrap_snapshots` for slot-to-epoch mapping, and the
  producer supplies its own staged bundle file.
- **I-095-MOCK (BLOCKING):** Every success-capable bootstrap double requires
  the same flag/path contract, while the real binary exposes the flag.
- **I-095-FAIL-CLOSED (BLOCKING):** Missing, malformed, and fixture-inconsistent
  history cannot yield a committed complete bundle and reports its actual
  boundary failure.
- **I-095-FIXTURE (BLOCKING):** PR 93's two fixture blobs are byte-identical and
  all remaining changes are confined to the declared integration delta.
- **I-095-LIVE (BLOCKING):** The exact fixture creates the complete bundle and
  the live producer/consumer boundary starts without the prior era-history
  refusal.
- **I-095-AUDIT (BLOCKING):** The accepted SHA has a complete fresh audit and
  exact-head required-context evidence.
- **I-095-RETIREMENT (BLOCKING):** A future upstream pin cannot silently retain
  a stale patch; equivalent upstream support requires patch removal and the
  same live boundary proof.

## Acceptance evidence

- Frozen non-realizing gate with observed baseline RED and negative controls.
- Commit-owner RED/GREEN receipts and clean local candidate without any Nix
  realization.
- One fresh independent audit pass unless its first report requires the one
  allowed owner repair and fresh re-audit.
- Hosted Build Gate and Live Bootstrap Producer green at the exact branch head.
- Exact fixture-blob, final-tree, PR metadata, and required-context receipts.
