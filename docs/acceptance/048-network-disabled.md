# 048 Acceptance: Network-Disabled Bootstrap + Relay Sync

Date: 2026-07-24T18:04:40Z
Image: amaru-bootstrap-producer:dev (built from feat/node-bootstrap-producer)
Amaru: pragma-org/amaru 4b40e8dff718f3b14655430f263c179ef07a1335 (bare origin/main)

## Producer (network-disabled, INTERNAL_NETWORK=true)

```
wrote /srv/amaru/testnet_42
```

## Docker Network (internal=true, no external egress)

```
{
  "Name": "cardano-amaru-testnet",
  "Internal": true,
  "Driver": "bridge"
}
```

## Relay-1 adopt-tip progression (crossing slot 2000+)

```
2026-07-24T17:52:59.176430Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=1200 tip.hash=95678e1c45aad8d4f8149d7d73a17ea8f71eae07553d10922d5583e7a8efd218 tip.block_height=215 max_block_height=337 suppressed=0
2026-07-24T17:53:05.011278Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=1810 tip.hash=45fe91fa634779ada69df1b5d07b93f98aa97d70ad8ec972660050d34f3ef218 tip.block_height=338 max_block_height=338 suppressed=122
2026-07-24T17:53:08.006284Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=1816 tip.hash=ac4baf7280695a4a4c3e4a110b15ef3edd6adfa509de9bf6e2a29b428a446866 tip.block_height=339 max_block_height=339 suppressed=0
2026-07-24T17:53:10.558825Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=1821 tip.hash=dbcdf91c4e8ef709b6e0a8459c2df42a6c5255d98a48c7265b16a3762643b354 tip.block_height=340 max_block_height=340 suppressed=0
2026-07-24T17:53:14.008970Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=1828 tip.hash=4f4d0ab4427473c6b86248214730104de6c0931c8920914747bc65164845ddba tip.block_height=342 max_block_height=342 suppressed=1
...
2026-07-24T17:54:42.150123Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=2004 tip.hash=f7da8f31a0e85e952d17568fdc5a828ef58842d9e8cce05157d1be0afe0f18c3 tip.block_height=376 max_block_height=376 suppressed=0
2026-07-24T17:54:45.008687Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=2010 tip.hash=d5e6c198ba0690c0599cdb27109d6b570eeff1803fd24c1b59d32e654914b791 tip.block_height=377 max_block_height=377 suppressed=0
2026-07-24T17:54:48.007399Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=2016 tip.hash=4efff149e82885f6a9ab3beb45c8f007d7d29d6a240915a6d07102a44d45bfbd tip.block_height=378 max_block_height=378 suppressed=0
2026-07-24T17:54:49.507902Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=2019 tip.hash=1da0218199dea87bd7bc4e30acdcb0e73d66e0e4cf32b5ac04268d181e434341 tip.block_height=380 max_block_height=380 suppressed=1
2026-07-24T17:54:50.513243Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=2021 tip.hash=a3c74e466a2edacf9b5fda79d576d0e05bf4adf6ebc3a5e05776c000992282cb tip.block_height=381 max_block_height=381 suppressed=0
```

## Relay-2 adopt-tip progression

```
2026-07-24T18:04:17.006846Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=3154 tip.hash=3e10d040b45fefc138653bb0425e66256334dc96fadb197118550d78eb0cb53d tip.block_height=622 max_block_height=622 suppressed=0
2026-07-24T18:04:19.005639Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=3158 tip.hash=487cf07ff046146f87797acc50e4bec28d7cfb5ad1e5902aa31a2adf6e95f93f tip.block_height=623 max_block_height=623 suppressed=0
2026-07-24T18:04:25.505998Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=3171 tip.hash=5af439c42e25783b653f6cb45f42af92a580c731a0f66830de21de9eebfbc45d tip.block_height=625 max_block_height=625 suppressed=1
2026-07-24T18:04:27.005579Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=3174 tip.hash=83759ff9b2f5b216890c8ac7b1589cbf2600f418c8164153fad4e437e3ed1e47 tip.block_height=627 max_block_height=627 suppressed=1
2026-07-24T18:04:32.507323Z  INFO amaru_consensus::stages::adopt_chain: adopted tip tip.slot=3185 tip.hash=9f9dc2e7218315ef6c956e0028516dac3f83c7bd966c9377a2ca2dec12f6823a tip.block_height=628 max_block_height=628 suppressed=0
```

## Panic / stake-distribution grep

```
relay-1 panics: 0
0
relay-1 no-stake: 0
0
relay-2 panics: 0
0
relay-2 no-stake: 0
0
```

## CA-cert fix (nix/bootstrap-producer-image.nix)

Added pkgs.cacert to image contents + SSL_CERT_FILE/SSL_CERT_DIR env vars.
This allows reqwest::Client::new() to succeed (reads CA certs from disk, no network).
snapshot create skips Koios when --snapshot is given; node bootstrap SKIP_DOWNLOADs local snapshots.
The producer makes ZERO actual network calls under INTERNAL_NETWORK=true.

## Follow-up (separate repo)

cardano-node-antithesis compose needs AMARU_GLOBAL_{CONSENSUS_SECURITY_PARAM=20,ACTIVE_SLOT_COEFF_INVERSE=5,EPOCH_LENGTH_SCALE_FACTOR=4} in amaru-relay env.
