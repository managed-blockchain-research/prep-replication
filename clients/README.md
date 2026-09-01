# PREP source patch

PREP's warm-score admission gate is implemented inside the same shared
scheduler file used by MATS (`applyPrepGate`, `PREP_MAX_DEFERRALS`,
`prepDeferralCount` in `LASTScheduler.java`) rather than as a separate class —
see `besu-mats/` (identical to the copy in this repo family's `mats` branch).
`nethermind-mats/LastTxPoolTxSource.cs` is the corresponding Nethermind port,
also shared with LAST/MATS.
