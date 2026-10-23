# Private Media Library

This context covers the on-device private media library and its discreet, release-configured application identity.

## Application icon language

**Icon Identity**:
One logical Home Screen icon design, independent of its system appearance and of the currently active decoy.

**Primary Icon**:
The standard icon identity available without an entitlement. The icon picker labels this identity "Default".
_Avoid_: Default Appearance

**Alternate Icon**:
A user-selectable icon identity other than the Primary Icon. The approved family contains seven Pro alternate identities.
_Avoid_: Icon Appearance, Variant

**Development Icon**:
A development-build icon identity that retains the Primary Icon's recognizable composition while visually distinguishing the build. It is not a Pro Alternate Icon.

**Icon Family**:
The related set of nine icon identities: one Primary Icon, seven Alternate Icons, and one Development Icon.

**Icon Appearance**:
A system presentation of an Icon Identity: Default, Dark, or Tinted. An appearance does not change the identity the user selected.
_Avoid_: Alternate Icon

**Active Icon**:
The Icon Identity currently displayed by the operating system. It is independent of the active decoy.
