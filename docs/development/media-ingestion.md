# Media ingestion

## Import order

An import first copies the selected file into protected staging and records the accepted bytes in the ingestion journal. The importer validates the staged image, then compares its complete resource collection with committed assets. Identity uses each resource's role and normalized SHA-256 digest. Resource order does not matter, repeated resources remain significant, and an empty or malformed collection cannot match.

When an asset matches, the journal records `awaitingUserDecision` with `duplicate_decision = pending`. The staged file stays available while the Library presents the choice. Dismissing the prompt only hides it for the current presentation; the journal remains pending so a later authenticated Library presentation can show it again.

## Journal decisions

The journal keeps ingestion state, duplicate choice, and quota result in separate columns. New rows begin with `quota_admission = pending`; old rows retain `NULL` after the additive migration.

| Journal state | Duplicate decision | Quota admission | Meaning |
| --- | --- | --- | --- |
| `awaitingUserDecision` | `pending` | `pending` | Keep staged bytes until Skip or Import Anyway is chosen. |
| `cancelled` | `skipped` | `pending` | Do not commit; remove this item's staged file during cleanup. |
| `duplicateCheck` | `overridden` | `pending` | Preserve the user's choice while checking quota. |
| `ready`, `committing`, or `complete` | `overridden` or `NULL` | `admitted` or legacy `NULL` | Commit or recover the accepted asset. |
| `failed` | `overridden` or `NULL` | `denied`, `pending`, or legacy `NULL` | Keep failure evidence and staged bytes; normal reconciliation does not retry failed rows. |

Skip and Import Anyway update the journal with one conditional SQLite write. If Import Anyway reaches the quota limit, the row keeps both `overridden` and `denied`. A later retry must preserve both markers.

## Recovery

Reconciliation skips valid pending duplicate decisions so they do not hold the durable-operation gate or block other imports. Rows with `admitted` continue without another entitlement lookup. Rows with `pending` must pass quota before reaching `ready`.

Legacy rows with `NULL` quota metadata keep the recovery behavior they had before this schema change, but only when their journal state and validation metadata are valid. Failed and cancelled rows remain terminal. A legacy `awaitingUserDecision` row without a duplicate marker is ambiguous and stays unreadable rather than being treated as a new decision.

Skip cleanup is safe to repeat and removes only the skipped resource's staging file. The importer checks the authenticated session generation before starting fresh work and before persisting a duplicate choice. Results from an older Library session are ignored after lock.

Quota reservations and retry management are tracked in Issues #15 and #16.
