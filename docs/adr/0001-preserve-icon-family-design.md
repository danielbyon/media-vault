# Preserve the approved icon family through faithful, editable artwork

Status: proposed (remaining packaging and platform-presentation decisions are still open).

## Context

The existing concept showcase is a small raster presentation, not production-resolution source artwork. A release build needs a primary icon, seven premium alternate designs, and a visibly distinct development identity. Each icon identity needs compatible system appearance treatments. Icon design is consumer-facing release identity, not part of the private-media domain.

## Decisions settled October 22, 2026

1. **Artwork provenance and fidelity.** Recreate the approved concept family faithfully at production resolution from editable masters, using the supplied original showcase as the canonical visual reference. Do not enlarge the cropped concept images and present them as mastered artwork. A reconstructed deliverable is not the original source asset and must be reviewed against the reference.
2. **Scope.** Prepare and integrate the full nine-identity family: Primary; premium Mineral, Indigo, Instrument, Grid, Compass, Calculator and Calculator Glass; and Development. Runtime selection UI, entitlement gating, and persistence remain to be explicitly scoped; this decision alone does not authorize changing those contracts.
3. **Appearance.** Prefer artwork-controlled fidelity to additional platform Liquid Glass embellishment. Preserve each identity's recognizable shape, relative proportions, and design intent across system appearances. Do not let OS effects materially reinterpret the approved glass/refraction highlights.
4. **Naming boundary.** Source and runtime identifiers remain semantic/role-based. Consumer-facing marketing/design names in the reference board are not source-domain names. Existing release identity configuration is the appropriate consumer-name boundary.

## Rejected alternatives and risks

- **Simple upscale:** The small icon crops embedded in the showcase cannot establish production-quality detail; upscale artifacts and invented highlights would risk divergence.
- **Native-effects-first reinterpretation:** Allowing automatic highlights/refraction to redefine the mark would compromise visual continuity with the approved design.
- **Primary-and-Development-only packaging:** This would leave the seven already-approved premium identities unresolved until the later selection feature; the current product decision is to prepare all identities together.

## Open boundaries for the next design round

- Exact editable master format and reproducible rendering/export toolchain.
- Whether to register alternate identities as launch-time bundle resources now or merely prepare/integrate their files pending the later picker feature; no runtime premium selection should bypass entitlement rules.
- Correct treatment of system-managed tinted/clear modes relative to the original reference board.
- Development-badge construction, visual signoff gates, and build/QA verification.
