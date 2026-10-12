# Private Media Vault domain

A local, authenticated media library with a browser as one explicit acquisition source. The glossary distinguishes temporary network activity, recoverable receipt, and visible canonical media.

## Browser and acquisition language

**Browser download**:
A WebKit-managed transfer started by ordinary webpage behavior. The result is temporary browser download content for supported preview, sharing, or disposal; it is not automatically a vault asset.
_Avoid_: Vault import, saved asset

**Save to Vault**:
A deliberate user action targeting one identifiable, supported, accessible media resource. Page loading, background resource fetching, and an ordinary download do not imply this action.
_Avoid_: Automatic media capture, page harvest

**Acquisition receipt**:
Completed original bytes controlled by the app in protected receipt staging, associated with opaque identity and minimal recovery metadata, awaiting a later authenticated ingestion decision. It is not yet a canonical media asset.
_Avoid_: Download history, imported asset

**Accepted receipt**:
An acquisition receipt whose protected bytes and recovery manifest have passed the receipt publication protocol. Acceptance does not assert that MediaLibrary has committed the asset or that data survived a power-loss event.
_Avoid_: Completed import

**Canonical media asset**:
A validated original with its resource and metadata committed to the single MediaLibrary store; the Library exposes only completed canonical assets.
_Avoid_: Receipt, downloaded file

**Ephemeral browsing**:
A WebKit browsing profile whose website state and tab session are not retained as durable browser state. An explicitly requested Save to Vault is a separate user-directed acquisition and may produce a durable receipt without retaining the browsing profile's cookies or tab history.

## Decision references

- docs/adr/0001-retain-wkwebview-visible-browser.md
- docs/adr/0002-separate-browser-downloads-and-vault-acquisition.md
- docs/research/browser-architecture-evidence-and-decision.md
