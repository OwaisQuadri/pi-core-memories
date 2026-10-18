# Build and setup

The app, command, and Pi integration share one memory store. Pi runs inference. The Swift core validates replies and publishes approved changes.

Build requirements are in [Package.swift](../Package.swift). Install [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) and sign in through Pi before using live dreams. This project supports Pi first.

## Build the app and command

Run from this checkout:

```zsh
scripts/package.zsh "$HOME/.local/share/pi-core-memories-runtime"
```

Choose a new output directory. The command refuses to replace an existing app or runtime. It builds with warnings treated as errors. It does not change Pi settings or initialize memory.

The output contains:

- `Core Memories.app`, with its own command and Pi control resources.
- `bin/pi-core-memories`.
- `lib/pi-core-memories/pi`, the command's Pi resources.

Keep the command and `lib` directories together. The app is self-contained. Move the app to Applications if you want it installed.

Add the command directory to your shell path:

```zsh
export PATH="$HOME/.local/share/pi-core-memories-runtime/bin:$PATH"
```

For a new memory store, use the separate data location shown in the app's Storage settings:

```zsh
memory_repo="/absolute/path/to/private-memory"
pi-core-memories init --repo "$memory_repo"
```

Do not initialize an existing store. Set the app's Memory repository field to the same location. Keep memory data outside the source repository.

## Install the Pi integration

After the command is on your path:

```zsh
pi install https://github.com/OwaisQuadri/pi-core-memories
```

Start a new Pi session. Set `PI_CORE_MEMORIES_REPO` when your data store differs from the loader's default. If you already use a separate core-memories extension, disable that copy before enabling this package. Do not load both copies.

The package adds memory loading, `/dream`, `/mem-review`, `/mem-rereview`, `/mem-prepare`, and the existing memory management tools. Installing the package does not approve candidates or run a dream.

## Dreams

The app shows saved runs, each saved attempt, its model selection, and reply validation failures. Expand a run to inspect its exact request, context, reply, or receipt. Inspection does not call a model or advance dream progress.

Start resumes saved work when present. Process All continues through the backlog and stops on a pending result. Retry Interrupted Call and Replace Invalid Reply require separate choices because they can make another billable call. Replacement retains the rejected reply and keeps the frozen validation rules.

Cancel affects only the invocation that the app owns. Other Pi sessions remain separate.

In Settings, select the Pi executable and agent directory. Empty selection fields use Pi defaults. Explicit provider, model, and thinking settings must match Pi's resolved selection before a request starts. Credentials stay in Pi's normal credential stores.

Agents can use the same configured command:

```zsh
pi-core-memories dream inspect
pi-core-memories dream start
pi-core-memories dream all
pi-core-memories dream retry
pi-core-memories dream replace
```

Use `--config <file>` for a separate app or command profile. Keep that file in a private, owner-only directory. The app accepts the same argument. `dream inspect --state <directory>` reads a selected saved state without starting an invocation.

## Edit and review

Memory edits persist as local drafts. Save Changes validates the whole draft and publishes one commit. An invalid annotation, stale base, changed target, or checkout conflict leaves approved memory unchanged. Unchanged retries retain the Save receipt's identity.

Use Prepare Checkout before the first publication from an attached initialization checkout. It preserves that checkout's files and index. It does not approve memory.

Dream candidates stay separate from edit drafts. Review shows a current preview, sources, contradictions, and the proposed change. Approve This Entry applies only that preview. Restoring a draft does not restore candidate approval authority.

Reveal Checkout in Finder opens the selected working-file location, or the repository folder when that file is not checked out. The editor reads committed approved bytes, not dirty working files. Existing Pi sessions keep their saved memory snapshot; start a new session to load changed memory.

## Device and project layers

Set Up This Device creates a random, machine-local key. Reads do not create a device identity. The key is not a hostname or hardware identifier. Do not sync the local configuration as if it were shared memory.

The New Memory menu offers global, this-device, project, and project-on-this-device targets. Other devices stay hidden by default. All devices shows them for explicit editing.

A project's default key follows its local canonical Git directory. To share a project across devices, reuse the first device's project key through an explicit binding on each other device:

```zsh
pi-core-memories project-key --cwd "$project"
pi-core-memories setup-device
pi-core-memories bind-project --cwd "$project" --key "$shared_project_key"
pi-core-memories scope
```

The app provides the same binding controls. Bindings do not rewrite old documents or pending contexts. Without a binding, moving a project changes its default key.

## Private data and remotes

Use a private remote for approved memory data. The app does not push, pull, or merge automatically. Sync approved main history through your normal Git process.

Keep dream inputs, rejected replies, draft journals, and invocation diagnostics outside both the public source tree and the committed memory tree. The configuration and private state locations come from `MemoryConfiguration` in the Swift core.

## Development checks

```zsh
swift build -Xswiftc -warnings-as-errors
PI_CORE_MEMORIES_BIN="$PWD/.build/debug/pi-core-memories" swift test -Xswiftc -warnings-as-errors
npm ci --ignore-scripts
node node_modules/typescript/bin/tsc --project tsconfig.json
PI_CORE_MEMORIES_BIN="$PWD/.build/debug/pi-core-memories" node --throw-deprecation --test Integration/Pi/*.test.ts
```

The tests use temporary stores and offline providers. They do not require a live model. Native screen checks must also use a separate fixture configuration, not a personal memory store.
