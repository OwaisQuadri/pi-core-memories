# Native runtime and installation

## Product boundary

Memory work belongs in ordinary Pi conversation. Background dreaming runs while interactive Pi sessions are open. The source builds a native worker, not a graphical application. The extension registers no slash commands or manual dreaming mode.

Removing the graphical application from this source does not uninstall an existing copy or delete its drafts, saved findings, and source evidence. Keep those records until the conversational replacement and migration pass acceptance. The [README](../README.md#public-pi-integration) describes the current integration.

## Build and package

Build requirements are in [Package.swift](../Package.swift). To package the native worker and Pi integration resources without installing them:

```sh
scripts/package.zsh "$HOME/.local/share/pi-core-memories-runtime"
```

Use a new output directory. Packaging refuses to replace an existing worker or runtime directory. It builds with warnings as errors and does not change Pi settings or initialize memory. The output contains `bin/pi-core-memories` and `lib/pi-core-memories/pi`. Keep those paths together.

## Install the Pi integration

```sh
pi install https://github.com/OwaisQuadri/pi-core-memories
```

Use checked, user-merged source. The package compile entrypoint is `Integration/Pi/compile.ts`. It uses [pi-compiled](https://github.com/OwaisQuadri/pi-compiled), requires upstream Git verification, and fails on build errors. Installation compilation never uses `PI_CORE_MEMORIES_EXECUTABLE` to skip that verification.

Session start uses the same compiler when needed. A progress bar shows the build. Memory loading and tools wait for readiness; their wait can be cancelled. A failed build or cleanup retains the previous executable and stamp. A matching executable and stamp do not trigger a scratch sweep. Swift Package Manager owns scratch cleanup.

`PI_CORE_MEMORIES_EXECUTABLE` can select an absolute worker for session verification. `PI_CORE_MEMORIES_REPO` selects the approved-memory repository. Neither grants approval or changes saved snapshots. Do not enable two copies of the extension.

Installing the package does not approve pending findings or grant model access. Use Pi's existing login and selected provider, model, and thinking level. Do not add a paid fallback or read credential files to make a check pass.

## Saved configuration and review

Keep memory and private state outside the public source tree. Configuration retains storage roots, source identity, diagnostics, scope keys, and project bindings. Existing serialized model-harness fields remain compatible with saved diagnostics; they do not launch models from an application.

The agent directory still identifies historical source data. Saved status is matched against its original profile. A missing or mismatched record stays unknown rather than being attached to another profile. The native worker can inspect saved state; that internal interface is not a command the user must run to get memory work done.

Keep native saved-data readers, batch drafts, checked receipts, and recovery checks until migration acceptance. Restoring a draft restores intent, not approval. A stale base, missing evidence, changed target, unverified save, or unresolved recovery blocks publication. Do not initialize an existing store, rewrite an archive, reset pending review state, or remove unknown locks.

Each Pi session retains its approved snapshot. A later memory change loads in a new session; it does not rewrite an existing session's context.

## Verification

Use affected-test selection for changed code. A fresh independent reviewer runs required complete suites on the current source. Native protocol tests do not prove background-to-chat handoff. That acceptance also needs exact chat presentation, trusted later approval, conversational changes, ownership and restart recovery, foreground priority, last-session shutdown, preserved data, and migration.

No test uses a personal memory store. No source check authorizes an installation, permission grant, model switch, or data deletion.
