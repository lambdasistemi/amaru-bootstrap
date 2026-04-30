{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

{- |
Module      : LedgerStateEmitter
Description : Emit Amaru-compatible ledger-state snapshots
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

@ledger-state-emitter@ opens a cardano-node chain DB, replays the
ledger state to a requested slot, and writes the Legacy
@ExtLedgerState@ CBOR envelope consumed by Amaru.

The encoder intentionally emits the Amaru bootstrap projection of a
cardano-node 10.7.1 ledger state. The outer Legacy @ExtLedgerState@
envelope stays consensus-compatible, but the Shelley-family payload is
adjusted where Amaru's importer still expects older ledger shapes:

* @UTxOState@ uses canonical @EncCBOR@ for @UTxO@/@TxOut@ entries
  instead of the ledger MemPack byte-string shortcut.
* The Shelley ledger wrapper omits the node-10.7.1 Peras certificate
  field because Amaru's converter slices only the @NewEpochState@ and
  still walks the surrounding wrapper in the pre-Peras shape.
* Conway/Dijkstra @PState@ is projected to the three fields Amaru
  imports: current pool params, future pool params, and retirements.
  The node-10.7.1 VRF-key index is an internal ledger acceleration
  structure, not part of Amaru's bootstrap store.
* Conway/Dijkstra @DState@ accounts are projected from the node-10.7.1
  account-state map back into the legacy delegation-state wrapper that
  Amaru imports. Per-account balance, deposit, stake-pool delegation,
  and DRep delegation are preserved; historical pointer indexes and the
  intermediate deposits accumulator are omitted because Amaru skips them
  during bootstrap.
-}
module LedgerStateEmitter (
    emitLedgerSnapshot,
) where

import Cardano.Ledger.BaseTypes (Network, knownNonZeroBounded, networkId)
import Cardano.Ledger.Binary.Encoding (
    EncCBOR (encCBOR),
    Encoding,
    fromPlainEncoding,
    toPlainEncoding,
 )
import Cardano.Ledger.Binary.Plain (ToCBOR (toCBOR))
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Compactible (fromCompact)
import Cardano.Ledger.Conway.State qualified as Conway
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Dijkstra.State ()
import Cardano.Ledger.Shelley.LedgerState qualified as SL
import Cardano.Ledger.State qualified as Ledger
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tools.DBAnalyser.Block.Cardano (
    Args (CardanoBlockArgs, configFile, threshold),
 )
import Cardano.Tools.DBAnalyser.HasAnalysis (
    HasProtocolInfo (mkProtocolInfo),
 )
import Codec.CBOR.Encoding qualified as CBOR
import Codec.CBOR.Write qualified as CBOR
import Codec.Serialise (encode)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Control.Monad (join, when)
import Control.Monad.Trans.Class (lift)
import Control.ResourceRegistry (
    ResourceRegistry,
    runWithTempRegistry,
    withRegistry,
 )
import Data.ByteString.Lazy qualified as LBS
import Data.Functor.Contravariant ((>$<))
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (Proxy))
import Data.SOP.BasicFunctors (K (K))
import Data.SOP.Functors (Flip (unFlip))
import Data.SOP.Strict (NP (Nil, (:*)), fn, type (-.->))
import HeaderExtractor (NodeConfig (NodeConfig))
import Ouroboros.Consensus.Block (
    GetHeader,
    blockNo,
    blockPoint,
    blockSlot,
    unBlockNo,
 )
import Ouroboros.Consensus.Byron.Ledger.Block (ByronBlock)
import Ouroboros.Consensus.Cardano.Block (
    CardanoBlock,
    CardanoCodecConfig,
    CardanoEras,
    CardanoLedgerConfig,
    CodecConfig (CardanoCodecConfig),
    HardForkLedgerConfig (CardanoLedgerConfig),
    StandardCrypto,
 )
import Ouroboros.Consensus.Config (
    TopLevelConfig,
    configCodec,
    configLedger,
    configStorage,
 )
import Ouroboros.Consensus.Config.SecurityParam (SecurityParam (SecurityParam))
import Ouroboros.Consensus.HardFork.Combinator.Basics (
    LedgerState (hardForkLedgerStatePerEra),
 )
import Ouroboros.Consensus.HardFork.Combinator.Serialisation.Common (
    encodeTelescope,
 )
import Ouroboros.Consensus.HeaderValidation (
    headerStatePoint,
 )
import Ouroboros.Consensus.Ledger.Abstract (
    ApplyBlock (getBlockKeySets),
    ComputeLedgerEvents (OmitLedgerEvents),
    EmptyMK,
    tickThenReapply,
    withLedgerTables,
 )
import Ouroboros.Consensus.Ledger.Extended (
    ExtLedgerCfg (ExtLedgerCfg),
    ExtLedgerState (headerState),
    encodeExtLedgerState,
    getExtLedgerCfg,
 )
import Ouroboros.Consensus.Ledger.SupportsProtocol (

 )
import Ouroboros.Consensus.Ledger.Tables (
    CanStowLedgerTables (stowLedgerTables),
    ValuesMK,
 )
import Ouroboros.Consensus.Ledger.Tables.Utils (applyDiffs)
import Ouroboros.Consensus.Node qualified as Node
import Ouroboros.Consensus.Node.InitStorage qualified as Node
import Ouroboros.Consensus.Node.ProtocolInfo (
    ProtocolInfo (pInfoConfig, pInfoInitLedger),
 )
import Ouroboros.Consensus.Shelley.Eras (
    AllegraEra,
    AlonzoEra,
    BabbageEra,
    ConwayEra,
    DijkstraEra,
    MaryEra,
    ShelleyEra,
 )
import Ouroboros.Consensus.Shelley.Ledger (
    LedgerState (
        ShelleyLedgerState,
        shelleyLedgerLatestPerasCertRound,
        shelleyLedgerState,
        shelleyLedgerTip,
        shelleyLedgerTransition
    ),
    ShelleyBlock,
    ShelleyCompatible,
    ShelleyLedgerConfig (shelleyLedgerGlobals),
    ShelleyPartialLedgerConfig (shelleyLedgerConfig),
    ShelleyTip (
        ShelleyTip,
        shelleyTipBlockNo,
        shelleyTipHash,
        shelleyTipSlotNo
    ),
    ShelleyTransition (ShelleyTransitionInfo, shelleyAfterVoting),
 )
import Ouroboros.Consensus.Storage.ChainDB.Impl.Args qualified as ChainDB
import Ouroboros.Consensus.Storage.Common (BlockComponent (GetBlock))
import Ouroboros.Consensus.Storage.ImmutableDB qualified as ImmutableDB
import Ouroboros.Consensus.Storage.ImmutableDB.Stream qualified as ImmutableDB
import Ouroboros.Consensus.Storage.LedgerDB qualified as LedgerDB
import Ouroboros.Consensus.Storage.LedgerDB.Snapshots (encodeL)
import Ouroboros.Consensus.Storage.LedgerDB.V2 qualified as LedgerDB.V2
import Ouroboros.Consensus.Storage.LedgerDB.V2.Backend qualified as V2Backend
import Ouroboros.Consensus.Storage.LedgerDB.V2.InMemory qualified as V2InMemory
import Ouroboros.Consensus.Storage.Serialisation (EncodeDisk (encodeDisk))
import Ouroboros.Consensus.Util.Args (Complete)
import Ouroboros.Consensus.Util.CBOR (
    encodeWithOrigin,
 )
import Ouroboros.Consensus.Util.Versioned (encodeVersion)
import Ouroboros.Network.Block (genesisPoint)
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

type LedgerEncoding = Encoding

type CanonicalShelleyLedgerCbor era =
    ( Core.EraTxOut era
    , Ledger.EraGov era
    , Ledger.EraStake era
    , Ledger.EraCertState era
    , EncCBOR (SL.StashedAVVMAddresses era)
    )

type ConwayCompatibleLedgerCbor era =
    ( CanonicalShelleyLedgerCbor era
    , Conway.ConwayEraCertState era
    , Conway.ConwayEraAccounts era
    )

-- | Emit a Legacy @ExtLedgerState@ CBOR file for the requested slot.
emitLedgerSnapshot ::
    -- | Chain DB directory.
    FilePath ->
    -- | cardano-node @config.json@.
    NodeConfig ->
    -- | First block slot at or after this slot is emitted.
    SlotNo ->
    -- | Output CBOR file.
    FilePath ->
    IO ()
emitLedgerSnapshot dbDir (NodeConfig configPath) targetSlot outFile = do
    pInfo <-
        mkProtocolInfo
            CardanoBlockArgs
                { configFile = configPath
                , threshold = Nothing
                }
    let cfg = pInfoConfig pInfo
    ledgerAtSlot <- replayToSlot dbDir cfg (pInfoInitLedger pInfo) targetSlot
    createDirectoryIfMissing True (takeDirectory outFile)
    LBS.writeFile outFile $
        CBOR.toLazyByteString $
            encodeL
                (encodeCanonicalExtLedgerState cfg)
                (stowLedgerTables ledgerAtSlot)

{- | Replay immutable blocks from the latest ledger snapshot to the
first block at or beyond the requested slot.
-}
replayToSlot ::
    FilePath ->
    TopLevelConfig (CardanoBlock StandardCrypto) ->
    ExtLedgerState (CardanoBlock StandardCrypto) ValuesMK ->
    SlotNo ->
    IO (ExtLedgerState (CardanoBlock StandardCrypto) ValuesMK)
replayToSlot dbDir cfg genesisLedger targetSlot =
    withRegistry $ \registry -> do
        let shfs = Node.stdMkChainDbHasFS dbDir
            chunkInfo = Node.nodeImmutableDbChunkInfo (configStorage cfg)
            flavargs =
                LedgerDB.LedgerDbBackendArgsV2 $
                    V2Backend.SomeBackendArgs V2InMemory.InMemArgs
            chainDbArgs0 =
                ChainDB.completeChainDbArgs
                    registry
                    cfg
                    genesisLedger
                    chunkInfo
                    (const True)
                    shfs
                    shfs
                    flavargs
                    ChainDB.defaultArgs
            chainDbArgs =
                chainDbArgs0
                    { ChainDB.cdbLgrDbArgs =
                        lowMemoryLedgerArgs (ChainDB.cdbLgrDbArgs chainDbArgs0)
                    }
            immutableDbArgs = ChainDB.cdbImmDbArgs chainDbArgs
            ledgerDbArgs = ChainDB.cdbLgrDbArgs chainDbArgs
        bracket
            (ImmutableDB.openDBInternal immutableDbArgs)
            (ImmutableDB.closeDB . fst)
            ( \(immutableDB, _) ->
                bracket
                    (openV2LedgerDB ledgerDbArgs)
                    LedgerDB.closeDB
                    ( \ledgerDB ->
                        replayLoop cfg registry immutableDB ledgerDB targetSlot
                    )
            )

lowMemoryLedgerArgs ::
    Complete LedgerDB.LedgerDbArgs IO (CardanoBlock StandardCrypto) ->
    Complete LedgerDB.LedgerDbArgs IO (CardanoBlock StandardCrypto)
lowMemoryLedgerArgs args =
    args
        { LedgerDB.lgrConfig =
            LedgerDB.LedgerDbCfg
                (SecurityParam (knownNonZeroBounded @1))
                (LedgerDB.ledgerDbCfg $ LedgerDB.lgrConfig args)
                OmitLedgerEvents
        }

openV2LedgerDB ::
    Complete LedgerDB.LedgerDbArgs IO (CardanoBlock StandardCrypto) ->
    IO (LedgerDB.LedgerDB' IO (CardanoBlock StandardCrypto))
openV2LedgerDB ledgerDbArgs =
    runWithTempRegistry $
        case LedgerDB.lgrBackendArgs ledgerDbArgs of
            LedgerDB.LedgerDbBackendArgsV2 (V2Backend.SomeBackendArgs backendArgs) -> do
                resources <-
                    V2Backend.mkResources
                        (Proxy @(CardanoBlock StandardCrypto))
                        ( LedgerDB.LedgerDBFlavorImplEvent
                            . LedgerDB.FlavorImplSpecificTraceV2
                            >$< LedgerDB.lgrTracer ledgerDbArgs
                        )
                        backendArgs
                        (LedgerDB.lgrHasFS ledgerDbArgs)
                let snapshotManager =
                        V2Backend.snapshotManager
                            (Proxy @(CardanoBlock StandardCrypto))
                            resources
                            ( configCodec
                                . getExtLedgerCfg
                                . LedgerDB.ledgerDbCfg
                                $ LedgerDB.lgrConfig ledgerDbArgs
                            )
                            ( LedgerDB.LedgerDBSnapshotEvent
                                >$< LedgerDB.lgrTracer ledgerDbArgs
                            )
                            (LedgerDB.lgrHasFS ledgerDbArgs)
                    initDb =
                        LedgerDB.V2.mkInitDb
                            ledgerDbArgs
                            noReplay
                            snapshotManager
                            ( LedgerDB.praosGetVolatileSuffix
                                . LedgerDB.ledgerDbCfgSecParam
                                $ LedgerDB.lgrConfig ledgerDbArgs
                            )
                            resources
                (ledgerDB, _, _) <-
                    lift $
                        LedgerDB.openDBInternal
                            ledgerDbArgs
                            initDb
                            snapshotManager
                            emptyStream
                            genesisPoint
                pure (ledgerDB, ())
            _ ->
                error
                    "LedgerStateEmitter.openV2LedgerDB: expected V2 LedgerDB backend"
  where
    noReplay _ = pure (error "LedgerStateEmitter.openV2LedgerDB: unexpected replay")

emptyStream :: (Applicative m) => ImmutableDB.StreamAPI m blk a
emptyStream = ImmutableDB.StreamAPI $ \_ k ->
    k $ Right $ pure ImmutableDB.NoMoreItems

replayLoop ::
    TopLevelConfig (CardanoBlock StandardCrypto) ->
    ResourceRegistry IO ->
    ImmutableDB.ImmutableDB IO (CardanoBlock StandardCrypto) ->
    LedgerDB.LedgerDB' IO (CardanoBlock StandardCrypto) ->
    SlotNo ->
    IO (ExtLedgerState (CardanoBlock StandardCrypto) ValuesMK)
replayLoop cfg registry immutableDB ledgerDB targetSlot = do
    initialLedger <- atomically $ LedgerDB.getVolatileTip ledgerDB
    let startPoint = headerStatePoint $ headerState initialLedger
    iterator <-
        ImmutableDB.streamAfterKnownPoint
            immutableDB
            registry
            GetBlock
            startPoint
    go initialLedger iterator
  where
    ledgerCfg = ExtLedgerCfg cfg

    go oldLedger iterator =
        ImmutableDB.iteratorNext iterator >>= \case
            ImmutableDB.IteratorExhausted ->
                fail $
                    "ledger-state-emitter: no immutable block at or after target slot "
                        <> show targetSlot
            ImmutableDB.IteratorResult block -> do
                LedgerDB.withTipForker ledgerDB $ \forker -> do
                    tables <- LedgerDB.forkerReadTables forker (getBlockKeySets block)
                    let oldLedgerWithTables =
                            oldLedger `withLedgerTables` tables
                        newLedger =
                            tickThenReapply
                                OmitLedgerEvents
                                ledgerCfg
                                block
                                oldLedgerWithTables
                        newLedgerWithValues =
                            applyDiffs oldLedgerWithTables newLedger
                    LedgerDB.forkerPush forker newLedger
                    join $ atomically $ LedgerDB.forkerCommit forker
                    -- Keep replay in-memory. Flushing here can prune
                    -- snapshots from a live cardano-node LedgerDB.
                    when ((unBlockNo $ blockNo block) `mod` 1000 == 0) $
                        putStrLn $
                            "ledger-state-emitter: replayed block "
                                <> show (blockNo block)
                                <> " at slot "
                                <> show (blockSlot block)
                    if blockSlot block >= targetSlot
                        then pure newLedgerWithValues
                        else go (stowLedgerTables newLedgerWithValues) iterator

{- | The stock extended-ledger-state envelope, but with the ledger-state
branch using canonical UTxO encoding.
-}
encodeCanonicalExtLedgerState ::
    TopLevelConfig (CardanoBlock StandardCrypto) ->
    ExtLedgerState (CardanoBlock StandardCrypto) EmptyMK ->
    CBOR.Encoding
encodeCanonicalExtLedgerState cfg =
    encodeExtLedgerState
        (encodeCardanoLedgerStateCanonical (configCodec cfg) (configLedger cfg))
        (encodeDisk $ configCodec cfg)
        (encodeDisk $ configCodec cfg)

encodeCardanoLedgerStateCanonical ::
    CardanoCodecConfig StandardCrypto ->
    CardanoLedgerConfig StandardCrypto ->
    LedgerState (CardanoBlock StandardCrypto) EmptyMK ->
    CBOR.Encoding
encodeCardanoLedgerStateCanonical
    ( CardanoCodecConfig
            cfgByron
            _cfgShelley
            _cfgAllegra
            _cfgMary
            _cfgAlonzo
            _cfgBabbage
            _cfgConway
            _cfgDijkstra
        )
    ( CardanoLedgerConfig
            _ledgerByron
            _ledgerShelley
            _ledgerAllegra
            _ledgerMary
            _ledgerAlonzo
            _ledgerBabbage
            ledgerConway
            ledgerDijkstra
        ) =
        encodeTelescope encoders . hardForkLedgerStatePerEra
      where
        conwayNetwork = partialLedgerConfigNetwork ledgerConway
        dijkstraNetwork = partialLedgerConfigNetwork ledgerDijkstra

        encoders ::
            NP
                (Flip LedgerState EmptyMK -.-> K CBOR.Encoding)
                (CardanoEras StandardCrypto)
        encoders =
            fn (K . encodeDisk cfgByron . unFlip)
                :* fn (K . encodeShelleyLedgerStateCanonical . unFlip)
                :* fn (K . encodeShelleyLedgerStateCanonical . unFlip)
                :* fn (K . encodeShelleyLedgerStateCanonical . unFlip)
                :* fn (K . encodeShelleyLedgerStateCanonical . unFlip)
                :* fn (K . encodeShelleyLedgerStateCanonical . unFlip)
                :* fn (K . encodeConwayLedgerStateCanonical conwayNetwork . unFlip)
                :* fn (K . encodeConwayLedgerStateCanonical dijkstraNetwork . unFlip)
                :* Nil

partialLedgerConfigNetwork ::
    ShelleyPartialLedgerConfig era ->
    Network
partialLedgerConfigNetwork =
    networkId . shelleyLedgerGlobals . shelleyLedgerConfig

encodeShelleyLedgerStateCanonical ::
    forall proto era.
    ( ShelleyCompatible proto era
    , CanonicalShelleyLedgerCbor era
    ) =>
    LedgerState (ShelleyBlock proto era) EmptyMK ->
    CBOR.Encoding
encodeShelleyLedgerStateCanonical =
    encodeShelleyLedgerStateCanonicalWith encodeNewEpochStateCanonical

encodeConwayLedgerStateCanonical ::
    forall proto era.
    ( ShelleyCompatible proto era
    , ConwayCompatibleLedgerCbor era
    ) =>
    Network ->
    LedgerState (ShelleyBlock proto era) EmptyMK ->
    CBOR.Encoding
encodeConwayLedgerStateCanonical network =
    encodeShelleyLedgerStateCanonicalWith $
        encodeNewEpochStateCanonicalWith (encodeConwayCertStateAmaru network)

encodeShelleyLedgerStateCanonicalWith ::
    forall proto era.
    (ShelleyCompatible proto era) =>
    (SL.NewEpochState era -> CBOR.Encoding) ->
    LedgerState (ShelleyBlock proto era) EmptyMK ->
    CBOR.Encoding
encodeShelleyLedgerStateCanonicalWith encodeNewEpochState
    ShelleyLedgerState
        { shelleyLedgerTip
        , shelleyLedgerState
        , shelleyLedgerTransition
        } =
        encodeVersion 2 $
            mconcat
                [ CBOR.encodeListLen 3
                , encodeWithOrigin encodeShelleyTip shelleyLedgerTip
                , encodeNewEpochState shelleyLedgerState
                , encodeShelleyTransition shelleyLedgerTransition
                ]

encodeShelleyTip :: ShelleyTip proto era -> CBOR.Encoding
encodeShelleyTip
    ShelleyTip
        { shelleyTipSlotNo
        , shelleyTipBlockNo
        , shelleyTipHash
        } =
        mconcat
            [ CBOR.encodeListLen 3
            , encode shelleyTipSlotNo
            , encode shelleyTipBlockNo
            , encode shelleyTipHash
            ]

encodeShelleyTransition :: ShelleyTransition -> CBOR.Encoding
encodeShelleyTransition ShelleyTransitionInfo{shelleyAfterVoting} =
    CBOR.encodeWord32 shelleyAfterVoting

encodeNewEpochStateCanonical ::
    forall era.
    (CanonicalShelleyLedgerCbor era) =>
    SL.NewEpochState era ->
    CBOR.Encoding
encodeNewEpochStateCanonical =
    encodeNewEpochStateCanonicalWith encCBOR

encodeNewEpochStateCanonicalWith ::
    forall era.
    (CanonicalShelleyLedgerCbor era) =>
    (SL.CertState era -> LedgerEncoding) ->
    SL.NewEpochState era ->
    CBOR.Encoding
encodeNewEpochStateCanonicalWith encodeCertState =
    toPlainEncoding (Core.eraProtVerLow @era)
        . encodeNewEpochStateCanonicalLedgerWith encodeCertState

encodeNewEpochStateCanonicalLedgerWith ::
    forall era.
    (CanonicalShelleyLedgerCbor era) =>
    (SL.CertState era -> LedgerEncoding) ->
    SL.NewEpochState era ->
    LedgerEncoding
encodeNewEpochStateCanonicalLedgerWith encodeCertState (SL.NewEpochState e bp bc es ru pd av) =
    mconcat
        [ fromPlainEncoding $ CBOR.encodeListLen 7
        , encCBOR e
        , encCBOR bp
        , encCBOR bc
        , encodeEpochStateCanonicalWith encodeCertState es
        , encCBOR ru
        , encCBOR pd
        , encCBOR av
        ]

encodeEpochStateCanonicalWith ::
    forall era.
    (CanonicalShelleyLedgerCbor era) =>
    (SL.CertState era -> LedgerEncoding) ->
    SL.EpochState era ->
    LedgerEncoding
encodeEpochStateCanonicalWith encodeCertState
    SL.EpochState
        { SL.esChainAccountState = esChainAccountState
        , SL.esLState = esLState
        , SL.esSnapshots = esSnapshots
        , SL.esNonMyopic = esNonMyopic
        } =
        mconcat
            [ fromPlainEncoding $ CBOR.encodeListLen 4
            , encCBOR esChainAccountState
            , encodeLedgerStateCanonicalWith encodeCertState esLState
            , encCBOR esSnapshots
            , encCBOR esNonMyopic
            ]

encodeLedgerStateCanonicalWith ::
    forall era.
    (CanonicalShelleyLedgerCbor era) =>
    (SL.CertState era -> LedgerEncoding) ->
    SL.LedgerState era ->
    LedgerEncoding
encodeLedgerStateCanonicalWith encodeCertState
    SL.LedgerState
        { SL.lsUTxOState = lsUTxOState
        , SL.lsCertState = lsCertState
        } =
        mconcat
            [ fromPlainEncoding $ CBOR.encodeListLen 2
            , encodeCertState lsCertState
            , encodeUTxOStateCanonical lsUTxOState
            ]

encodeConwayCertStateAmaru ::
    forall era.
    (ConwayCompatibleLedgerCbor era) =>
    Network ->
    SL.CertState era ->
    LedgerEncoding
encodeConwayCertStateAmaru network certState =
    mconcat
        [ fromPlainEncoding $ CBOR.encodeListLen 4
        , encCBOR $ certState ^. Conway.certVStateL
        , encodePStateAmaru network $ certState ^. Ledger.certPStateL
        , encodeSkippedDepositsAmaru
        , encodeDStateAmaru $ certState ^. Ledger.certDStateL
        ]

encodePStateAmaru ::
    Network ->
    Ledger.PState era ->
    LedgerEncoding
encodePStateAmaru network pState =
    mconcat
        [ fromPlainEncoding $ CBOR.encodeListLen 3
        , encCBOR $
            Map.mapWithKey
                (Ledger.stakePoolStateToStakePoolParams network)
                (Ledger.psStakePools pState)
        , encCBOR $ Ledger.psFutureStakePoolParams pState
        , encCBOR $ Ledger.psRetiring pState
        ]

encodeSkippedDepositsAmaru :: LedgerEncoding
encodeSkippedDepositsAmaru =
    fromPlainEncoding $ CBOR.encodeMapLen 0

encodeDStateAmaru ::
    forall era.
    (Conway.ConwayEraAccounts era) =>
    Ledger.DState era ->
    LedgerEncoding
encodeDStateAmaru dState =
    mconcat
        [ fromPlainEncoding $ CBOR.encodeListLen 4
        , encodeAccountsAmaru $ dState ^. Ledger.accountsL
        , encCBOR $ Ledger.dsFutureGenDelegs dState
        , encCBOR $ Ledger.dsGenDelegs dState
        , encCBOR $ Ledger.dsIRewards dState
        ]

encodeAccountsAmaru ::
    forall era.
    (Conway.ConwayEraAccounts era) =>
    Ledger.Accounts era ->
    LedgerEncoding
encodeAccountsAmaru accounts =
    mconcat $
        [ fromPlainEncoding $ CBOR.encodeListLen 2
        , fromPlainEncoding $ CBOR.encodeMapLen $ fromIntegral $ Map.size accountStates
        ]
            <> concatMap encodeAccountMapEntry (Map.toAscList accountStates)
            <> [encodeEmptySetAmaru]
  where
    accountStates = accounts ^. Ledger.accountsMapL

    encodeAccountMapEntry (credential, accountState) =
        [ encCBOR credential
        , encodeAccountStateAmaru accountState
        ]

encodeAccountStateAmaru ::
    forall era.
    (Conway.ConwayEraAccounts era) =>
    Ledger.AccountState era ->
    LedgerEncoding
encodeAccountStateAmaru accountState =
    mconcat
        [ fromPlainEncoding $ CBOR.encodeListLen 4
        , encodeRewardsAndDepositAmaru accountState
        , encodeEmptySetAmaru
        , encodeStrictMaybeAmaru $
            accountState ^. Ledger.stakePoolDelegationAccountStateL
        , encodeStrictMaybeAmaru $
            accountState ^. Conway.dRepDelegationAccountStateL
        ]

encodeRewardsAndDepositAmaru ::
    forall era.
    (Conway.ConwayEraAccounts era) =>
    Ledger.AccountState era ->
    LedgerEncoding
encodeRewardsAndDepositAmaru accountState =
    mconcat
        [ fromPlainEncoding $ CBOR.encodeListLen 1
        , fromPlainEncoding $ CBOR.encodeListLen 2
        , encCBOR (fromCompact (accountState ^. Ledger.balanceAccountStateL) :: Coin)
        , encCBOR (fromCompact (accountState ^. Ledger.depositAccountStateL) :: Coin)
        ]

encodeStrictMaybeAmaru :: (EncCBOR a) => Maybe a -> LedgerEncoding
encodeStrictMaybeAmaru =
    \case
        Nothing -> fromPlainEncoding $ CBOR.encodeListLen 0
        Just value ->
            mconcat
                [ fromPlainEncoding $ CBOR.encodeListLen 1
                , encCBOR value
                ]

encodeEmptySetAmaru :: LedgerEncoding
encodeEmptySetAmaru =
    fromPlainEncoding $ CBOR.encodeListLen 0

encodeUTxOStateCanonical ::
    forall era.
    (CanonicalShelleyLedgerCbor era) =>
    SL.UTxOState era ->
    LedgerEncoding
encodeUTxOStateCanonical
    SL.UTxOState
        { SL.utxosUtxo = utxosUtxo
        , SL.utxosDeposited = utxosDeposited
        , SL.utxosFees = utxosFees
        , SL.utxosGovState = utxosGovState
        , SL.utxosInstantStake = utxosInstantStake
        , SL.utxosDonation = utxosDonation
        } =
        mconcat
            [ fromPlainEncoding $ CBOR.encodeListLen 6
            , encCBOR utxosUtxo
            , encCBOR utxosDeposited
            , encCBOR utxosFees
            , encCBOR utxosGovState
            , encCBOR utxosInstantStake
            , encCBOR utxosDonation
            ]
