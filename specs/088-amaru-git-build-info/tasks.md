# Tasks: deterministic Amaru git build information

Artifact ceiling: 60 lines.

## Slice S-088-01 — locked build identity

- [x] T088-01 Freeze the compact mandate and pre-change failing static gate.
- [ ] T088-02 Supply D-088-FULL, D-088-SHORT, and D-088-DIRTY to every Amaru
  package variant without `.git`, source patches, or impurity.
- [ ] T088-03 Make `checks.x86_64-linux.amaru` execute the packaged version
  surface and reject a missing, mismatched, or dirty identity.
- [ ] T088-04 Record commit-owner RED/GREEN evidence and a clean candidate.
- [ ] T088-05 Obtain a fresh independent audit pass on the exact candidate.
- [ ] T088-06 Obtain green hosted full CI at the stock pin.
- [ ] T088-07 Obtain green hosted full CI on the isolated PR #87-shape fixture.
- [ ] T088-08 Finalize PR metadata and hand off the exact green head for review.
