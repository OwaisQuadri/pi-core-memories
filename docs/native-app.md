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

```zsh
pi install https://github.com/OwaisQuadri/pi-core-memories
```

Start a new Pi session. The package builds its own command with [pi-compiled](https://github.com/OwaisQuadri/pi-compiled) into `target/release/pi-core-memories` inside the installed clone. It builds in the background at session start when the command is missing or its committed Swift source changed, which includes the first start after `pi install` or `pi update`. Until the first build finishes, memory loading, `/dream`, and the review commands wait for it; the memory review reminder waits for the next session. It refuses to build unless `HEAD` is the fetched upstream commit, so install from a branch, not a pinned tag or commit. It also refuses uncommitted, untracked, or ignored source changes. `build.zsh` fails when a `.swiftpm` directory exists, and it deletes its build cache first. Set `PI_CORE_MEMORIES_EXECUTABLE` to an absolute path to use another build instead. The Pi package does not use the command on your path. Set `PI_CORE_MEMORIES_REPO` when your data store differs from the loader's default. If you already use a separate core-memories extension, disable that copy before enabling this package. Do not load both copies.

The package adds memory loading, `/dream`, `/mem-review`, `/mem-rereview`, `/mem-prepare`, and the existing memory management tools. Installing the package does not approve candidates or run a dream.

## Find suggestions

Choose Find Suggestions to process recent conversations. The queue shows dreamt text, undreamt text, and free queue capacity. Batch sizes come from runtime measurements; unavailable measurements stay unknown.

Review Suggestions opens the Memories workspace. To Review, Changes, Blocked, and Saved History remain separate groups beside the editor and final Save Changes control. A finished run and a manual refresh reload the suggestions. Review each proposed result before choosing Stage Acceptance.

If approved memories changed after a reply was saved, choose Prepare Saved Suggestions. Inspect the saved suggestions and their blockers, then confirm Prepare for Review. This action makes no model call and changes no approved memories. Each compatible suggestion still needs separate review and approval. Changed or ambiguous targets stay blocked.

Details contains saved runs, attempts, model selection, validation failures, and exact artifacts. Inspection does not call a model or advance dream progress.

Other Actions includes processing all waiting batches. Retry Interrupted Call and Replace Invalid Reply can make another billable call. Neither repairs a saved reply whose publication stopped after approved memories changed. Replacement retains the rejected reply and keeps the frozen validation rules.

Stop Finding Suggestions affects only the invocation that the app owns. Other Pi sessions remain separate.

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

Review choices and memory edits stage in one local draft. Save Changes validates every staged item and publishes one approved-memory commit. A draft containing only Decide Later and Dismiss choices saves decisions without creating a commit. An invalid annotation, stale base, changed target, or checkout conflict prevents publication. Remove and staged Undo change the next Save's contents. They do not reverse a completed Save.

Use Prepare Checkout before the first publication from an attached initialization checkout. It preserves that checkout's files and index. It does not approve memory.

Select a suggestion to inspect its original proposal, approved-before text, and final result. Choose Stage Acceptance, Decide Later, or Dismiss to stage its disposition. To correct a suggestion, choose Edit Suggestion, retain its sources, enter a reason, and choose Preview Amendment. Inspect the amended result before choosing Stage Acceptance. The original proposal and provenance remain intact.

Staged suggestions appear only in Changes, not To Review. Successful triage of the selected To Review item selects and prepares the next unstaged suggestion, continuing across catalog pages and wrapping to remaining earlier items. The last item clears the selection. A failed action keeps the current review. Removing or undoing a staged choice makes its suggestion available again. Restored publishing choices stay in Changes with Needs Review until freshly inspected and staged.

The Review menu owns these shortcuts on macOS 13 and later:

- Command-Return stages acceptance of the displayed result.
- Command-Shift-D stages Decide Later.
- Command-Shift-X stages Dismiss.

Inspector buttons use the same guarded actions and show the keys in tooltips. Held-key repeats are rejected before an action starts. Shortcuts are disabled outside Memories, for incompatible selections, dirty or unreviewed amendments, pending recovery, or busy or unresolved Saves. Preview Amendment still requires explicit Stage Acceptance. Changing selection, draft ownership, or input invalidates a captured action rather than applying it to another suggestion.

Supported additions, updates, deletions, and Confirm Reviewed also stage in this workspace. Confirm Reviewed requires inspection of its exact result before Stage Confirm Reviewed. Save Changes, the toolbar, and Command-S use the same final Save action. Command-Z uses text undo in an active editor and staged undo elsewhere.

Draft persistence runs separately from prepared interaction. A crash can lose input that has not received a persistence acknowledgment. Restoring a draft restores intent, not approval authority. Each restored publishing suggestion and Confirm Reviewed row requires fresh inspection and staging. Details contains exact sources, diagnostics, paths, and receipts. Recovery-required or unknown Save outcomes block another publication until exact recovery resolves them.

Recovery Required lists retained Saves whose consumption cannot currently be verified. Select a row for read-only Details. To continue separate manual work, explicitly open a distinct manual draft from Details, or choose Start Manual Batch… and confirm. These actions leave recovery pending and unchanged. Review actions remain blocked until Refresh verifies the history. Refresh preserves the selected independent manual draft and its prepared scope.

Terminal review remains explicitly confirmed one item at a time. It uses the shared transaction owner, not the native batch's Save action. Memory management commands remain create, read, update, and delete operations. They cannot approve suggestions or save a review-bearing batch.

Reveal Checkout in Finder opens the selected working-file location, or the repository folder when that file is not checked out. The editor reads committed approved bytes, not dirty working files. Existing Pi sessions keep their saved memory snapshot; start a new session to load changed memory.

## Device and project layers

Set Up This Device creates a random, machine-local key. Reads do not create a device identity. The key is not a hostname or hardware identifier. Do not sync the local configuration as if it were shared memory.

The New Memory menu offers global, this-device, project, and project-on-this-device targets. Other devices stay hidden by default. All devices shows them for explicit editing.

Memory rows and the review inspector label the actual target as Global, a project name, This device, or Another device. Project names come from configured Git-directory bindings or matching recorded source working directories, not from the memory text. Names are prepared with the catalog outside interactive triage. Missing context shows Project (name unavailable). Conflicting names show Project (ambiguous name). Details retains exact target paths, keys, and recorded or configured directories. These labels do not change target scope or approval authority.

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
PI_CORE_MEMORIES_BIN="$(swift build --show-bin-path)/pi-core-memories" swift test -Xswiftc -warnings-as-errors
npm ci --ignore-scripts
node node_modules/typescript/bin/tsc --project tsconfig.json
PI_CORE_MEMORIES_BIN="$(swift build --show-bin-path)/pi-core-memories" node --throw-deprecation --test Integration/Pi/*.test.ts
```

The tests use temporary stores and offline providers. They do not require a live model. Native screen checks must also use a separate fixture configuration, not a personal memory store.

The opt-in review drivers use the same twelve-suggestion fixture with four retained approvals and eight timed approvals. Build release tests with warnings treated as errors. Set CORE_MEMORY_REVIEW_BASELINE=1 or CORE_MEMORY_REVIEW_BATCH=1 and filter the corresponding ReviewFlow test. CORE_MEMORY_REVIEW_REPETITION selects one repetition from zero through five. Zero is the warmup. Without that variable, each driver runs the warmup and five measured repetitions. For a before-and-after comparison, run the baseline against frozen pre-change production sources and alternate equivalent repetitions.

PI_NATIVE_PREPARED_TARGET=1 enables nativeThirtySuggestionPreparedActionTarget. It reports prepared model-command timings separately from preparation, durability, and final Save with reconciliation. These checks do not measure rendered-interface latency.
