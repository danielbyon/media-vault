# Build Artifact Cleanup

## 1. Operational prerequisite

**Run `make clean` only when no build, test, or other cleanup operation is active in the checkout.**

Cleanup assumes a trusted operator and a stable checkout. It handles ordinary
mistakes and filesystem errors; it does not defend against another process
changing repository paths while cleanup is running.

## 2. Invocation

From the checkout root:

```sh
make clean
```

The `-C` form also works because `make` changes into the named checkout:

```sh
make -C /absolute/path/to/media-vault clean
```

The helper verifies that its process working directory is the Git checkout
that contains the selected Makefile. It rejects `make -f` when invoked from
another directory. Paths containing spaces are supported.

Cleanup needs Git and Python 3 to read tracked `Package.resolved` files. It
does not need Xcode, SwiftPM, network access, or a previously completed build.

## 3. Removed artifacts

The only cleanup candidate is a complete dependency checkout below:

```text
.build/SourcePackages/checkouts/<dependency>
```

A candidate is removed only when all of these checks pass:

1. Its directory name matches a package identity or remote repository basename
   in a tracked project lockfile.
2. The lockfile is one of:
   - `App.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   - `App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   - `Packages/ApplicationFoundation/Package.resolved`
3. The lockfile path contains no symbolic-link component and the main checkout
   does not track a file below the dependency checkout.
4. The dependency is a complete Git checkout whose own `.git` directory is at
   that root. A linked worktree, nested repository, submodule, or checkout that
   registers another worktree is preserved.
5. `HEAD` equals the tracked pin revision and `origin` equals the tracked pin
   location after removing a trailing slash or `.git`.
6. The dependency has no modified, untracked, or ignored content.

When those checks pass, cleanup removes the whole dependency checkout,
including its working tree and local Git metadata. Files tracked by that
dependency are package content that SwiftPM can restore from the pinned
revision. The command never removes files tracked by the main project.

Local source-control pins, checkouts cloned from a local SwiftPM mirror, linked
worktrees, submodules, and conflicting pins are ambiguous under these simple
ownership checks. Cleanup preserves and reports them.

## 4. Preserved artifacts

Cleanup preserves:

1. The `.build`, `.build/SourcePackages`, and
   `.build/SourcePackages/checkouts` containers.
2. `.build/SourcePackages/repositories`, `workspace-state.json`, and other
   cache observations.
3. Stale `.build/xcodebuild-build.*` and `.build/xcodebuild-test.*`
   directories, including their DerivedData and logs.
4. `.build/swiftlint` and lookalikes such as `.build/swiftlint-cache`.
5. Root `DerivedData`, root `build`, `.build/DerivedData`,
   `.build/xcodebuild-archive.*`, and other unknown build-like paths.
6. Package-local `.build` and `build` directories, along with application,
   framework, and XCTest bundles outside an eligible dependency checkout.
7. Source, tests, fixtures, snapshots, artwork, credentials, local
   configuration, `.git`, `.chatgpt`, `.tools`, `.codegraph`, `.serena`,
   `.swiftpm`, `xcuserdata`, and `.DS_Store`.
8. Other worktrees, independent repositories, unknown content, and targets
   referenced by symbolic links outside the checkout.

The `build` and `test` recipes each create a unique temporary directory and
remove that exact path with an exit trap. A later `make clean` has no reliable
way to classify an old directory from its name alone, so it does not scan or
delete stale Xcode prefix matches.

## 5. Output and accounting

The command prints one line for each removed or skipped candidate. It also
prints this summary:

```text
clean: inspected 2 candidate(s), removed 1, skipped 1, reclaimed 2048 KiB
```

The reclaimed value is the sum of allocated size reported by `du -sk` for
successfully removed checkouts. It is not a measurement of physical free-space
change. Filesystem accounting can differ from the value reported here.

A fresh or repeated cleanup succeeds when no candidate exists. Ambiguous
content is skipped without failing the command. An inspection or deletion
error is reported, the affected candidate is preserved where possible, and
the command exits nonzero. A failed recursive removal can leave a partially
removed directory; cleanup does not attempt a rollback.

## 6. Regeneration

SwiftPM recreates removed dependency checkouts when a supported Make target
needs them. Regeneration may require network access.

```sh
make tools
make build
make test
```

SwiftLint state and Xcode build products are recreated by their normal
tooling. Developers can inspect preserved stale directories and remove them
manually after deciding what owns their contents.

## 7. Focused tests

Run the disposable fixture suite with:

```sh
make clean-test
```

The suite creates temporary Git repositories below the system temporary
directory. It exercises normal removal, missing and repeated cleanup, checkout
paths containing spaces, symlink boundaries, tracked and protected content,
unknown and independent repositories, worktrees, package-local products,
reporting, and ordinary inspection and deletion failures. It uses no Xcode,
SwiftPM, or network access.

The default CI interpreter is macOS Bash 3.2. When Bash 5 is available, the
same suite can target it with:

```sh
CLEAN_TEST_SHELL=/path/to/bash make clean-test
```

## 8. Qualification limits

The suite validates the helper and Make invocation behavior in disposable
checkouts. It does not create real Xcode or SwiftPM caches, prove how an
arbitrary third-party repository manages submodules or mirrors, or test
concurrent cleanup. Those cases are outside the approved idle-checkout model;
ambiguous repositories are preserved.
