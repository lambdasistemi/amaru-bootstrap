# Functions model

Artifact ceiling: 55 lines.

- `bootstrap_snapshots(network: NetworkName, era_history: &EraHistory,
  s3: &AnonymousS3Client) -> Result<(PathBuf, Vec<Snapshot>), Box<dyn Error>>`:
  uses the supplied effective history for snapshot slot-to-epoch mapping.
- `bootstrap(network: NetworkName, global_parameters: &GlobalParameters,
  era_history: &EraHistory, ledger_dir: PathBuf, chain_dir: PathBuf,
  target_epoch: Option<Epoch>, s3_config: S3Config) -> Result<(), Box<dyn
  Error>>`: carries the effective history into bootstrap snapshot discovery;
  other effects and ownership remain unchanged.
- `node bootstrap Args.era_history: Option<PathBuf>`: same long option,
  environment variable, value name, and custom-network requirement as `node
  run`.
- `phase_bootstrap() -> process exit/effects`: supplies
  D-095-ERA-HISTORY-INPUT to `amaru node bootstrap`; preserves producer exit 9
  and atomic commit behavior.

No other public CLI, function signature, or runtime effect changes.
