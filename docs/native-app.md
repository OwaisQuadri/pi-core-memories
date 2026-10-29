# Native application and installation

## Product boundary

Memory work belongs in ordinary Pi conversation. Dreaming runs in the
background while interactive Pi sessions are open. The extension registers no
slash commands and has no manual dreaming or separate review mode.

The source no longer offers app-launched model calls or a Pi command adapter.
The legacy application's dreaming view reads saved records. Historical status
is not a live monitor of every background call.

The existing installed application, drafts, saved findings, and source evidence
remain until replacement and migration pass acceptance. Do not uninstall or
replace it merely because command removal passes. Its retained review and draft
actions are recovery facilities, not the recommended conversation interface.

The [README](../README.md#public-pi-integration) records the current source
implementation boundary. Source code, a menu, or another application cannot
stand in for installed replacement and migration acceptance.

## Build

Build requirements are in [Package.swift](../Package.swift). From the checkout:

```sh
scripts/package.zsh "$HOME/.local/share/pi-core-memories-runtime"
```

Use a new output directory. Packaging refuses to replace an existing app or
runtime. It builds with warnings as errors and does not change Pi settings or
initialize memory.

The output contains `Core Memories.app`, `bin/pi-core-memories`, and
`lib/pi-core-memories/pi`. The integration resources contain no command adapter.
Keep the executable and resource directories together. Packaging is not
installation, migration, or retirement approval.

## Install the Pi integration

```sh
pi install https://github.com/OwaisQuadri/pi-core-memories
```

Use checked, user-merged source. The package compile entrypoint is
`node Integration/Pi/compile.ts`. It uses
[pi-compiled](https://github.com/OwaisQuadri/pi-compiled), requires upstream Git
verification, and fails on build errors. Installation compilation never uses
`PI_CORE_MEMORIES_EXECUTABLE` to skip that verification.

Session start uses the same compiler when needed. A progress bar shows the
build. Memory loading and tools wait for readiness; their wait can be cancelled.
A failed build or cleanup command retains the previous executable and stamp.
A matching executable and stamp do not cause a scratch sweep. Swift Package
Manager owns scratch cleanup. Cleanup success does not promise an empty cache.

`PI_CORE_MEMORIES_EXECUTABLE` can select an absolute executable for session
verification. `PI_CORE_MEMORIES_REPO` selects the approved-memory repository.
Neither supplies approval or changes stored snapshots. Do not enable two copies
of the extension.

Installing the package does not approve pending findings or grant model access.
Use Pi's established login, selected provider, model, and thinking level. Do not
add a paid fallback or read credential files to make a check pass.

## Saved configuration

Keep memory and private state outside the public source tree. Configuration
retains storage roots, source identity, diagnostics, scope keys, and project
bindings. Existing serialized model-harness fields remain compatible with saved
diagnostics; they no longer launch models from the application.

The agent directory still identifies historical source data. Saved status is
matched against its original profile. A missing or mismatched record stays
unknown rather than being attached to another profile.

A diagnostic reader can inspect saved state through the native executable.
That internal interface is not a command the user must run to get memory work
done. Removed manual generation operations fail rather than launching a hidden
replacement or selecting an alternate profile.

Do not initialize an existing store, rewrite an archive, reset pending review
state, or remove unknown locks. Keep unresolved recovery and unsupported
historical findings visible with their limitations.

## Retained saved review

Keep native saved-data readers, batch drafts, checked receipts, and recovery
checks until migration acceptance. Restoring a draft restores intent, not
approval. A stale base, missing evidence, changed target, unverified Save,
or unresolved recovery blocks the affected publication.

The application's normal shutdown still flushes input and persistence and
checks unresolved saves. Removing a model-launch task must not remove those
safeguards.

Each Pi session retains its approved snapshot. A later memory change loads in
a new session; it does not silently rewrite an existing session's context.

## Device and project scope

Native catalogues supply exact device and project keys. Device setup creates a
random local key, not a hostname or hardware identifier. Reads do not create an
identity. Explicit project bindings let the same scope be used on another
machine without rewriting historical source context.

Configured paths and keys are private integration data. Do not copy them into
public tickets, examples, screenshots, or repository history.

## Verification

Use affected-test selection for changed code. A fresh independent reviewer runs
required complete suites on the current source. Keep native worker and saved
artifact safety coverage when deleting command-only fixtures.

Native protocol tests and saved-view screenshots do not prove background-to-chat
handoff. That acceptance also needs exact chat presentation, trusted later
approval, conversational changes, ownership and restart recovery, foreground
priority, last-session shutdown, preserved data, and migration.

No test uses a personal memory store. No source check authorizes an installed
application change, permission grant, model switch, or data deletion.
