import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test, type TestContext } from "node:test";
import type { AssistantMessage, Context, Model } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { DreamCoverage, DreamRequest, DreamStart } from "./dream.ts";

import { sdkURL, aiURL } from "./test/host.ts";
const dream = await import("./dream.ts");
const { default: coreMemories } = await import("./index.ts");
const sdk = await import(sdkURL) as typeof import("@earendil-works/pi-coding-agent");
const ai = await import(aiURL) as typeof import("@earendil-works/pi-ai");
const binary = process.env.PI_CORE_MEMORIES_BIN;
assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the verified release command");

async function fixture(t: TestContext, isPrimary = true) {
	const root = await mkdtemp("/private/tmp/pi-dream-adapter-");
	const home = join(root, "home"); const agent = join(home, "agent"); const repo = join(root, "memory ' ; $repo"); const bin = join(root, "bin");
	const previous = Object.fromEntries(["HOME", "PATH", "PI_CORE_MEMORIES_REPO", "PI_CODING_AGENT_DIR"].map((name) => [name, process.env[name]]));
	const previousFetch = globalThis.fetch; let networkCalls = 0;
	globalThis.fetch = async () => { networkCalls++; throw new Error("Network forbidden"); };
	t.after(async () => {
		globalThis.fetch = previousFetch;
		for (const [name, value] of Object.entries(previous)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
		await rm(root, { recursive: true, force: true }); assert.equal(networkCalls, 0);
	});
	await mkdir(agent, { recursive: true }); await mkdir(bin); await symlink(resolve(binary!), join(bin, "pi-core-memories"));
	process.env.HOME = home; process.env.PI_CODING_AGENT_DIR = agent; process.env.PI_CORE_MEMORIES_REPO = repo; process.env.PATH = `${bin}:${previous.PATH}`;
	const cli = (...args: string[]) => execFileSync(binary!, args, { encoding: "utf8" });
	cli("init", "--repo", repo);
	const folder = join(agent, "sessions", "synthetic-project"); await mkdir(folder, { recursive: true });
	const sessionFile = join(folder, "synthetic.jsonl");
	await writeFile(sessionFile, [
		{ type: "session", version: 3, id: "synthetic-session", timestamp: "1999-01-01T00:00:00.000Z", cwd: root },
		...(isPrimary ? [{ type: "message", id: "entry", parentId: null, timestamp: "1999-01-01T00:00:00.000Z", message: { role: "user", content: "Use green buttons, café 🌱, not blue.", timestamp: 0 } }] : []),
	].map((entry) => JSON.stringify(entry) + "\n").join(""));
	const roots = await dream.dreamRoots(agent, root);
	const selection = { provider: "fixture", modelID: "selected", thinkingLevel: "off" };
	const start: DreamStart = { version: 1, type: "start", invocationID: "synthetic-invocation", roots, selection, resume: "inspectOrContinue", batchTextBytes: 262_144 };
	return { root, home, agent, repo, bin, roots, start, sessionFile, cli };
}
function decision(request: DreamRequest, isProposal = false): string {
	const context = JSON.parse(request.messages[0].text) as { primaryEvidence: { source: unknown }[] };
	return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: context.primaryEvidence.map((entry) => isProposal ? { kind: "add", scope: { kind: "global" }, text: "Use green buttons.", sources: [entry.source], contradictions: [], reason: "Retain the preference." } : { kind: "noChange", sources: [entry.source], reasonCode: "notDurable", explanation: "Synthetic café 🌱 note." }) });
}

test("real worker publishes exact refs and notes once, saved retry and no-new use zero registry calls", async (t) => {
	for (const isProposal of [false, true]) {
		const f = await fixture(t); let calls = 0;
		const sourceBefore = await readFile(f.sessionFile); const approvedBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
		const first = await dream.runDreamWorker(f.start, async (request) => { calls++; return decision(request, isProposal); }, new AbortController().signal);
		assert.equal(first.status, "completed"); assert.equal(first.generation, "1"); assert.equal(calls, 1);
		assert.equal(first.proposals.length, isProposal ? 1 : 0); assert.equal(first.notes.length, isProposal ? 0 : 1);
		if (isProposal) {
			const proposal = first.proposals[0];
			const review = f.cli("review", "--repo", f.repo, proposal.commit);
			assert.ok(review.includes(proposal.base)); assert.match(review, /Use green buttons/); assert.match(review, /HUMAN/);
		}
		const forbidden = async () => { assert.fail("No registry call allowed on replay"); };
		const recovered = await dream.runDreamWorker({ ...f.start, selection: { provider: "other", modelID: "other", thinkingLevel: "high" }, resume: "retryInterruptedCall" }, forbidden, new AbortController().signal);
		assert.equal(recovered.status, "completed"); assert.equal(recovered.isRecovered, true); assert.deepEqual(recovered.proposals, first.proposals);
		const next = await dream.runDreamWorker(f.start, forbidden, new AbortController().signal);
		assert.equal(next.status, "noNewRecords"); assert.equal(next.generation, "1");
		assert.deepEqual(await readFile(f.sessionFile), sourceBefore); assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), approvedBefore);
	}
});

test("worker reports preserve source identifiers longer than generated protocol identifiers", async (t) => {
	const f = await fixture(t);
	const sessionID = "a".repeat(257);
	const entryID = "_" + "b".repeat(257);
	const records = (await readFile(f.sessionFile, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
	records[0].id = sessionID; records[1].id = entryID;
	await writeFile(f.sessionFile, records.map((entry) => JSON.stringify(entry) + "\n").join(""));
	const report = await dream.runDreamWorker(f.start, async (request) => decision(request, true), new AbortController().signal);
	assert.equal(report.status, "completed"); assert.equal(report.generation, "1");
	assert.deepEqual(report.proposals[0].sources, [{ sessionID, entryID, partIndex: 0 }]);
});

test("interrupted call stays pending, explicit retry uses exact saved input after source deletion", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined;
	const controller = new AbortController();
	const pending = await dream.runDreamWorker(f.start, async (request) => { saved = request; controller.abort(); throw new Error("cancel"); }, controller.signal);
	assert.equal(pending.status, "pending"); assert.equal(pending.reason, "cancelled");
	await rm(f.roots.sessions, { recursive: true });
	const roots = await dream.dreamRoots(f.agent, f.root);
	assert.deepEqual(roots, f.roots);
	const inspect = await dream.runDreamWorker({ ...f.start, roots }, async () => { assert.fail("inspect must not call"); }, new AbortController().signal);
	assert.equal(inspect.status, "pending"); assert.equal(inspect.reason, "interruptedCall");
	const completed = await dream.runDreamWorker({ ...f.start, roots, resume: "retryInterruptedCall" }, async (request) => { assert.deepEqual(request, saved); return decision(request); }, new AbortController().signal);
	assert.equal(completed.status, "completed"); assert.equal(completed.generation, "1");
});

test("real worker forwards provider stream errors, saves no response, and calls again only on explicit retry", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined; let calls = 0;
	const model = { provider: f.start.selection.provider, id: f.start.selection.modelID, api: "offline" } as Parameters<typeof dream.callDreamModel>[2];
	const memoryBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
	const report = await dream.runDreamWorker(f.start, async (request, signal) => {
		saved = request;
		const registry = { streamSimple(current, _context, _options) {
			calls++;
			const reply: AssistantMessage = { role: "assistant", api: current.api, provider: current.provider, model: current.id, content: [{ type: "text", text: "PRIVATE PARTIAL RESPONSE" }], stopReason: "error", errorMessage: "fixture provider quota exceeded", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
			const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "error", reason: "error", error: reply }); return stream;
		} } satisfies Pick<Parameters<typeof dream.callDreamModel>[1]["modelRegistry"], "streamSimple">;
		return dream.callDreamModel(request, { modelRegistry: registry as Parameters<typeof dream.callDreamModel>[1]["modelRegistry"] }, model, f.start.selection, signal);
	}, new AbortController().signal);
	assert.equal(report.status, "pending"); assert.equal(report.reason, "callbackFailure"); assert.equal(report.generation, "0"); assert.equal(calls, 1);
	assert.equal(report.detail, "Model call: Dream model call failed: provider error: fixture provider quota exceeded");
	const display = dream.dreamReviewText(report);
	assert.ok(display.includes(`Cause: ${report.detail}`)); assert.ok(display.includes("Use /dream retry only")); assert.ok(!display.includes("PRIVATE PARTIAL RESPONSE"));
	const directory = join(f.roots.state, "runs", report.runID!);
	await assert.rejects(readFile(join(directory, "response.json")), { code: "ENOENT" });
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
	const inspect = await dream.runDreamWorker(f.start, async () => { assert.fail("Inspection must not repeat the failed model call"); }, new AbortController().signal);
	assert.equal(inspect.status, "pending"); assert.equal(inspect.reason, "interruptedCall"); assert.equal(calls, 1);
	await assert.rejects(readFile(join(directory, "response.json")), { code: "ENOENT" });
	const completed = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, async (request) => {
		calls++; assert.deepEqual(request, saved); return decision(request);
	}, new AbortController().signal);
	assert.equal(completed.status, "completed"); assert.equal(completed.runID, report.runID); assert.equal(completed.generation, "1"); assert.equal(calls, 2);
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
});

test("saved owner byte mismatch reports its exact cause and cannot be replaced by retry or changed selection", async (t) => {
	const f = await fixture(t); let calls = 0;
	const owner = join(f.root, "style.md"); await writeFile(owner, "# Synthetic owner\n\nKeep this rule.\n");
	const start = { ...f.start, roots: { ...f.start.roots, globalAgents: owner } };
	const first = await dream.runDreamWorker(start, async (request) => {
		calls++;
		const context = JSON.parse(request.messages[0].text) as { primaryEvidence: { source: unknown }[]; ownerAnchorsNotPrimaryEvidence: Record<string, unknown>[] };
		const anchor = { ...context.ownerAnchorsNotPrimaryEvidence[0], start: 0, end: 16, before: "# Synthetic owner" };
		return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: [{ kind: "ownerNote", sources: [context.primaryEvidence[0].source], owner: anchor, contradictions: [], explanation: "The owner contains the rule." }] });
	}, new AbortController().signal);
	assert.equal(first.status, "pending"); assert.equal(first.reason, "invalidDecision"); assert.equal(calls, 1);
	assert.equal(first.detail, 'decision(index: 0, category: "owner anchor bytes do not match pinned slice")');
	const next = await dream.runDreamWorker({ ...start, resume: "retryInterruptedCall" }, async () => { assert.fail("Saved invalid response cannot be replaced"); }, new AbortController().signal);
	assert.equal(next.reason, "invalidDecision"); assert.equal(next.generation, "0"); assert.equal(next.detail, first.detail);
	const changed = await dream.runDreamWorker({ ...start, selection: { provider: "other", modelID: "changed", thinkingLevel: "high" } }, async () => { assert.fail("Saved response cannot be replaced"); }, new AbortController().signal);
	assert.equal(changed.status, "pending"); assert.equal(changed.reason, "invalidDecision"); assert.equal(changed.detail, first.detail);
	const replacement = await dream.runDreamWorker({ ...start, resume: "replaceInvalidResponse" }, async (request) => {
		const context = JSON.parse(request.messages[0].text) as { primaryEvidence: { source: unknown }[]; ownerAnchorsNotPrimaryEvidence: Record<string, unknown>[] };
		return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: [{ kind: "ownerNote", sources: [context.primaryEvidence[0].source], owner: context.ownerAnchorsNotPrimaryEvidence[0], contradictions: [], explanation: "The owner contains the rule." }] });
	}, new AbortController().signal);
	assert.equal(replacement.status, "completed"); assert.equal(replacement.generation, "1"); assert.equal(replacement.runID, first.runID); assert.equal(replacement.notes[0].kind, "ownerNote");
	const directory = join(start.roots.state, "runs", first.runID!);
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), await readFile(join(directory, "response.json")));
});

test("explicit replace command alone dispatches current selection and archives rejected bytes", async (t) => {
	const f = await fixture(t);
	let handler!: (args: string, ctx: import("@earendil-works/pi-coding-agent").ExtensionCommandContext) => Promise<void>;
	const entries: { report: import("./dream.ts").DreamReport }[] = [];
	const shutdown = dream.registerDream({ registerCommand: (_name: string, command: { handler: typeof handler }) => { handler = command.handler; }, registerEntryRenderer: () => {}, appendEntry: (_name: string, data: { report: import("./dream.ts").DreamReport }) => entries.push(data), getThinkingLevel: () => "off" } as unknown as ExtensionAPI);
	t.after(shutdown);
	const calls: { model: unknown; context: Context; reasoning: unknown }[] = [];
	const current = { provider: "other", id: "current", api: "offline", contextWindow: 262_144 };
	const registry = { streamSimple(model, context, options) {
		calls.push({ model, context, reasoning: options?.reasoning });
		const payload = JSON.parse(context.messages[0].content as string) as { contextHash: string; primaryEvidence: { source: unknown }[] };
		const text = calls.length === 1 ? " \nInvalid café 🌱 reply\r\n " : JSON.stringify({ schemaVersion: 1, contextHash: payload.contextHash, decisions: payload.primaryEvidence.map((entry) => ({ kind: "noChange", sources: [entry.source], reasonCode: "notDurable", explanation: "Offline replacement." })) });
		const reply: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id, content: [{ type: "text", text }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
		const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "done", reason: "stop", message: reply }); stream.end(reply); return stream;
	} } satisfies Pick<Parameters<typeof dream.callDreamModel>[1]["modelRegistry"], "streamSimple">;
	const ctx = { cwd: f.root, mode: "rpc", model: { provider: "fixture", id: "selected", api: "offline", contextWindow: 262_144 }, thinkingLevel: "off", waitForIdle: async () => {}, ui: { notify: () => {} }, modelRegistry: registry };
	const commandContext = ctx as unknown as import("@earendil-works/pi-coding-agent").ExtensionCommandContext;
	const memoryBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
	await handler("", commandContext);
	assert.equal(entries.at(-1)!.report.reason, "invalidDecision"); assert.equal(calls.length, 1);
	const runID = entries[0].report.runID!;
	const directory = join(f.roots.state, "runs", runID);
	const original = await readFile(join(directory, "response.json"));
	const names = ["input.json", "context.json", "request.json"];
	const frozen = await Promise.all(names.map((name) => readFile(join(directory, name))));
	for (const argument of ["", "retry", "all"]) {
		await handler(argument, commandContext); assert.equal(calls.length, 1); assert.equal(entries.at(-1)!.report.reason, "invalidDecision");
	}
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
	await rm(f.roots.sessions, { recursive: true });
	ctx.model = current; ctx.thinkingLevel = "high";
	await handler("replace", commandContext);
	assert.equal(calls.length, 2); assert.strictEqual(calls[1].model, current); assert.equal(calls[1].reasoning, "high"); assert.deepEqual(calls[1].context, calls[0].context);
	assert.equal(entries.at(-1)!.report.status, "completed"); assert.equal(entries.at(-1)!.report.runID, runID); assert.equal(entries.at(-1)!.report.generation, "1");
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), original);
	assert.deepEqual(await readFile(join(directory, "response.json")), original);
	assert.deepEqual(await Promise.all(names.map((name) => readFile(join(directory, name)))), frozen);
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
	await handler("replace", commandContext); assert.equal(calls.length, 2); assert.equal(entries.at(-1)!.report.status, "blocked");
});

test("interrupted replacement needs explicit retry, retains original, and uses current selection", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined;
	const first = await dream.runDreamWorker(f.start, async (request) => { saved = request; return "Invalid café 🌱"; }, new AbortController().signal);
	assert.equal(first.reason, "invalidDecision");
	const directory = join(f.roots.state, "runs", saved!.runID);
	const original = await readFile(join(directory, "response.json"));
	const replacing: DreamStart = { ...f.start, resume: "replaceInvalidResponse", selection: { provider: "other", modelID: "current", thinkingLevel: "high" } };
	const pending = await dream.runDreamWorker(replacing, async (request) => {
		assert.deepEqual(request, { ...saved, selection: replacing.selection });
		assert.deepEqual(await readFile(join(directory, "rejected-1.json")), original);
		throw new Error("Offline interrupted replacement");
	}, new AbortController().signal);
	assert.equal(pending.reason, "callbackFailure"); assert.equal(pending.generation, "0");
	const forbidden = async () => { assert.fail("Only explicit retry can repeat an interrupted replacement"); };
	for (const start of [f.start, replacing]) {
		const inspect = await dream.runDreamWorker(start, forbidden, new AbortController().signal);
		assert.equal(inspect.reason, "interruptedCall"); assert.equal(inspect.generation, "0");
	}
	await rm(f.roots.sessions, { recursive: true });
	const retry: DreamStart = { ...replacing, resume: "retryInterruptedCall", selection: { provider: "third", modelID: "latest", thinkingLevel: "medium" } };
	const completed = await dream.runDreamWorker(retry, async (request) => {
		assert.deepEqual(request, { ...saved, selection: retry.selection }); return decision(request);
	}, new AbortController().signal);
	assert.equal(completed.status, "completed"); assert.equal(completed.generation, "1"); assert.equal(completed.runID, saved!.runID);
	assert.deepEqual(await readFile(join(directory, "response.json")), original);
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), original);
	const replay = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, forbidden, new AbortController().signal);
	assert.equal(replay.status, "completed"); assert.equal(replay.runID, saved!.runID);
});

test("resumed worker dispatches current provider, model and thinking with exact frozen context", async (t) => {
	for (const selection of [
		{ provider: "other", modelID: "selected", thinkingLevel: "off" },
		{ provider: "fixture", modelID: "other", thinkingLevel: "off" },
		{ provider: "fixture", modelID: "selected", thinkingLevel: "high" },
	]) {
		const f = await fixture(t); let saved: DreamRequest | undefined;
		const first = await dream.runDreamWorker(f.start, async (request) => { saved = request; throw new Error("interrupted"); }, new AbortController().signal);
		assert.equal(first.status, "pending"); assert.ok(saved);
		const directory = join(f.roots.state, "runs", saved.runID);
		const names = ["input.json", "context.json", "request.json"];
		const frozen = await Promise.all(names.map((name) => readFile(join(directory, name))));
		await rm(f.roots.sessions, { recursive: true });
		const start = { ...f.start, selection, resume: "retryInterruptedCall" } as DreamStart;
		const model = { provider: selection.provider, id: selection.modelID, api: "openai-responses" } as Parameters<typeof dream.callDreamModel>[2];
		let calls = 0;
		const report = await dream.runDreamWorker(start, async (request, signal) => {
			assert.deepEqual(request, { ...saved, selection });
			const registry = { streamSimple(current, context, options) {
				calls++; assert.strictEqual(current, model);
				assert.equal(options?.reasoning, selection.thinkingLevel === "off" ? undefined : "high");
				assert.equal(context.systemPrompt, saved!.systemPrompt);
				assert.deepEqual(context.messages, saved!.messages.map((message) => ({ role: message.role, content: message.text, timestamp: message.timestampMilliseconds })));
				const reply: AssistantMessage = { role: "assistant", api: current.api, provider: current.provider, model: current.id, content: [{ type: "text", text: decision(request) }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
				const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "done", reason: "stop", message: reply }); stream.end(reply); return stream;
			} } satisfies Pick<Parameters<typeof dream.callDreamModel>[1]["modelRegistry"], "streamSimple">;
			return dream.callDreamModel(request, { modelRegistry: registry as Parameters<typeof dream.callDreamModel>[1]["modelRegistry"] }, model, selection, signal);
		}, new AbortController().signal);
		assert.equal(report.status, "completed"); assert.equal(calls, 1);
		assert.deepEqual(await Promise.all(names.map((name) => readFile(join(directory, name)))), frozen);
		const response = JSON.parse(await readFile(join(directory, "response.json"), "utf8"));
		assert.deepEqual(response.selection, selection);
		const recovered = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, async () => { assert.fail("Durable response must not call again"); }, new AbortController().signal);
		assert.equal(recovered.status, "completed"); assert.equal(recovered.runID, report.runID);
	}
});

test("missing sources block before registry", async (t) => {
	const f = await fixture(t);
	await rm(f.roots.sessions, { recursive: true });
	const missing = await dream.runDreamWorker(f.start, async () => { assert.fail("Missing source cannot call"); }, new AbortController().signal);
	assert.equal(missing.status, "blocked");
});

test("concurrent worker is busy while first registry call holds the core lock", async (t) => {
	const f = await fixture(t); let release!: () => void; let entered!: () => void;
	const wait = new Promise<void>((done) => { release = done; }); const ready = new Promise<void>((done) => { entered = done; });
	const first = dream.runDreamWorker(f.start, async (request) => { entered(); await wait; return decision(request); }, new AbortController().signal);
	await ready;
	const second = await dream.runDreamWorker({ ...f.start, invocationID: "second" }, async () => { assert.fail("busy must not call"); }, new AbortController().signal);
	assert.equal(second.status, "busy"); release(); assert.equal((await first).status, "completed");
});

test("exclusions-only complete and no-new records never call registry", async (t) => {
	const f = await fixture(t, false);
	const forbidden = async () => { assert.fail("No primary evidence, no registry call"); };
	assert.equal((await dream.runDreamWorker(f.start, forbidden, new AbortController().signal)).status, "completed");
	assert.equal((await dream.runDreamWorker(f.start, forbidden, new AbortController().signal)).status, "noNewRecords");
});

for (const action of ["escape", "shutdown"] as const) test(`native BorderedLoader ${action} aborts registry, reaps worker, and leaves recoverable pending state`, { timeout: 10000 }, async (t) => {
	const f = await fixture(t); sdk.initTheme("dark", false);
	let handler!: (args: string, ctx: import("@earendil-works/pi-coding-agent").ExtensionCommandContext) => Promise<void>;
	let loader: import("@earendil-works/pi-coding-agent").BorderedLoader | undefined;
	let signal: AbortSignal | undefined;
	let entered!: () => void; const ready = new Promise<void>((done) => { entered = done; });
	const entries: unknown[] = [];
	const pi = { registerCommand: (_name: string, command: { handler: typeof handler }) => { handler = command.handler; }, registerEntryRenderer: () => {}, appendEntry: (_name: string, data: unknown) => entries.push(data), getThinkingLevel: () => "off" } as unknown as ExtensionAPI;
	const shutdown = dream.registerDream(pi);
	t.after(async () => { await shutdown(); loader?.dispose(); });
	let isDismissed = false;
	const ctx = { cwd: f.root, mode: "tui", model: { provider: "fixture", id: "selected", api: "fixture", contextWindow: 262_144 }, thinkingLevel: "off", waitForIdle: async () => {},
		modelRegistry: { streamSimple(_model: unknown, _context: unknown, options: { signal: AbortSignal }) {
			signal = options.signal; entered();
			return { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }), result: () => new Promise(() => {}) };
		} },
		ui: { notify: () => {}, custom: (factory: (...args: unknown[]) => unknown) => new Promise((done) => {
			loader = factory({ requestRender: () => {} }, { fg: (_name: string, value: string) => value }, {}, (value: unknown) => { isDismissed = true; loader?.dispose(); done(value); }) as typeof loader;
		}) },
	} as unknown as import("@earendil-works/pi-coding-agent").ExtensionCommandContext;
	const work = handler("", ctx); await Promise.race([ready, work.then(() => assert.fail("Command stopped before registry call"))]);
	if (action === "escape") {
		loader!.handleInput("\u001b"); assert.equal(isDismissed, true); assert.equal(signal?.aborted, true);
	} else { await shutdown(); }
	await work; loader?.dispose();
	assert.equal(signal?.aborted, true);
	assert.equal(entries.length, action === "escape" ? 1 : 0);
	const pending = await dream.runDreamWorker(f.start, async () => { assert.fail("Inspect must not call"); }, new AbortController().signal);
	assert.equal(pending.status, "pending"); assert.equal(pending.reason, "interruptedCall");
});

test("installed native virtual resolver keeps logical selection and validates observed physical dispatch without payload access", async (t) => {
	const f = await fixture(t);
	const runtime = await sdk.ModelRuntime.create({ authPath: join(f.agent, "auth.json"), modelsPath: null, modelsStorePath: join(f.agent, "models.json"), allowModelNetwork: false, refreshOnCreate: false });
	const baseline = runtime.getModels("openai").find((item) => item.reasoning); assert.ok(baseline);
	const native: Model<"offline-native-api"> = { provider: "offline-native", id: "physical", name: "Offline physical model", api: "offline-native-api", baseUrl: "https://fixture.invalid", reasoning: true, input: ["text"], cost: { ...baseline.cost }, contextWindow: baseline.contextWindow, maxTokens: baseline.maxTokens };
	let nativeCalls = 0; let routes = 0;
	const payload = new Proxy({}, { get: () => assert.fail("Payload must not be inspected"), ownKeys: () => assert.fail("Payload must not be serialized") });
	const scripted: typeof runtime.streamSimple = (current, _context, options) => {
		nativeCalls++; assert.equal(current.id, native.id); assert.equal(current.provider, native.provider); assert.equal(options?.reasoning, "high");
		assert.ok(options?.onPayload); assert.equal(options.onPayload(payload, current), undefined);
		assert.equal(options.onPayload(payload, current), undefined);
		const reply: AssistantMessage = { role: "assistant", api: current.api, provider: current.provider, model: current.id, content: [{ type: "text", text: "exact native text" }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
		const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "done", reason: "stop", message: reply }); stream.end(reply); return stream;
	};
	runtime.registerNativeProvider(ai.createProvider({ id: native.provider, auth: { apiKey: { name: "Offline fixture", resolve: async () => ({ auth: {}, source: "fixture" }) } }, models: [native], api: { stream: scripted, streamSimple: scripted } }));
	await runtime.refresh({ allowNetwork: false });
	runtime.registerVirtualModel({ provider: "offline-virtual", id: "selected", name: "Offline virtual selection", thinkingLevels: ["medium"], route: (routing) => {
		routes++; assert.equal(routing.reason, "direct"); assert.equal(routing.thinkingLevel, "medium"); assert.equal(routing.model.api, "pi-virtual");
		assert.ok(JSON.stringify(routing.messages).includes("EXACT saved context"));
		return { model: native, thinkingLevel: "high" };
	} });
	const captured = runtime.getModelOfType("chat", "offline-virtual", "selected"); assert.ok(captured);
	const selection = { provider: captured.provider, modelID: captured.id, thinkingLevel: "medium" };
	const request = { version: 1, type: "modelRequest", invocationID: "invocation", requestID: "run:" + "a".repeat(64), runID: "run", generation: "0", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection, systemPrompt: "EXACT saved context", messages: [{ role: "user", text: "saved input", timestampMilliseconds: 0 }] } as DreamRequest;
	const registry = new sdk.ModelRegistry(runtime);
	assert.equal(await dream.callDreamModel(request, { modelRegistry: registry }, captured, selection, new AbortController().signal), "exact native text");
	assert.equal(routes, 1); assert.equal(nativeCalls, 1); assert.equal(captured.api, "pi-virtual"); assert.equal(request.selection.thinkingLevel, "medium");
});

test("installed SDK command lifecycle captures selection and stores review outside model and human input", async (t) => {
	const f = await fixture(t);
	const runtime = await sdk.ModelRuntime.create({ authPath: join(f.agent, "auth.json"), modelsPath: null, modelsStorePath: join(f.agent, "models.json"), allowModelNetwork: false, refreshOnCreate: false });
	const model = runtime.getModels("openai").find((item) => !item.reasoning && item.contextWindow >= 65_536); assert.ok(model);
	const requests: { model: unknown; context: Context; reasoning: unknown }[] = [];
	runtime.streamSimple = (current, context, options) => {
		requests.push({ model: current, context, reasoning: options?.reasoning });
		assert.equal(context.tools, undefined); assert.ok(!JSON.stringify(context).includes("ACTIVE CONVERSATION MUST NOT BE MINED"));
		assert.ok(!JSON.stringify(context).includes("CURRENT LOADER MUST NOT BE APPENDED"));
		const request = { messages: context.messages.map((item) => ({ text: typeof item.content === "string" ? item.content : "", role: item.role, timestampMilliseconds: item.timestamp })), contextHash: JSON.parse(typeof context.messages[0].content === "string" ? context.messages[0].content : "").contextHash } as DreamRequest;
		const content = JSON.parse(request.messages[0].text) as { primaryEvidence: { source: unknown }[] };
		const text = JSON.stringify({ schemaVersion: 1, contextHash: contentHash(context), decisions: content.primaryEvidence.map((entry) => ({ kind: "noChange", sources: [entry.source], reasonCode: "notDurable", explanation: "Offline SDK note." })) });
		const reply: AssistantMessage = { role: "assistant", api: current.api, provider: current.provider, model: current.id, content: [{ type: "text", text }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
		const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "done", reason: "stop", message: reply }); stream.end(reply); return stream;
	};
	const settingsManager = sdk.SettingsManager.inMemory({ retry: { enabled: false }, cacheWarming: "off", compaction: { enabled: false } });
	const loader = new sdk.DefaultResourceLoader({ cwd: f.root, agentDir: f.agent, settingsManager, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi: ExtensionAPI) => coreMemories(pi, async () => "CURRENT LOADER MUST NOT BE APPENDED")] });
	await loader.reload();
	const manager = sdk.SessionManager.inMemory(f.root); manager.appendMessage({ role: "user", content: "ACTIVE CONVERSATION MUST NOT BE MINED", timestamp: 0 });
	const { session } = await sdk.createAgentSession({ cwd: f.root, agentDir: f.agent, resourceLoader: loader, modelRuntime: runtime, model, thinkingLevel: "off", settingsManager, sessionManager: manager, tools: [] });
	t.after(() => session.dispose());
	const errors: string[] = [];
	await session.bindExtensions({ mode: "rpc", onError: (error) => errors.push(error.error) });
	const before = manager.getBranch().filter((entry) => entry.type === "message" && entry.message.role === "user").length;
	await session.prompt("/dream");
	assert.equal(requests.length, 1); assert.strictEqual(requests[0].model, model); assert.equal(requests[0].reasoning, undefined);
	assert.equal(session.model, model); assert.equal(session.thinkingLevel, "off"); assert.deepEqual(session.getActiveToolNames(), []);
	const reviews = manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === dream.DREAM_REVIEW_TYPE);
	assert.equal(reviews.length, 1); assert.equal(manager.getBranch().filter((entry) => entry.type === "message" && entry.message.role === "user").length, before);
	assert.ok(!JSON.stringify(manager.buildSessionProjection().messages).includes("Offline SDK note."));
	await session.prompt("/dream retry"); await session.prompt("/dream"); assert.equal(requests.length, 1); assert.deepEqual(errors, []);
});
function contentHash(context: Context): string {
	const payload = JSON.parse(typeof context.messages[0].content === "string" ? context.messages[0].content : "") as Record<string, unknown>;
	assert.equal(typeof payload.contextHash, "string");
	return payload.contextHash as string;
}

async function scriptedWorker(t: TestContext, script: string): Promise<void> {
	const root = await mkdtemp("/private/tmp/dream-protocol-"); const old = process.env.PATH;
	t.after(async () => { process.env.PATH = old; await rm(root, { recursive: true, force: true }); });
	await writeFile(join(root, "pi-core-memories"), `#!${process.execPath}\nif (process.argv[2] === "scope") { process.stdout.write(JSON.stringify({ deviceKey: null, projectBindings: {} }) + "\\n"); process.exit(0); }\n${script}\n`, { mode: 0o755 }); await chmod(join(root, "pi-core-memories"), 0o755);
	process.env.PATH = `${root}:${old}`;
}
const protocolStart: DreamStart = { version: 1, type: "start", invocationID: "invocation", roots: { state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }, selection: { provider: "fixture", modelID: "selected", thinkingLevel: "off" }, resume: "inspectOrContinue", batchTextBytes: 262_144 };
const protocolFinal = { version: 1, type: "final", invocationID: "invocation", status: "noNewRecords", generation: "0", runID: null, base: null, proposals: [], notes: [], isBacklog: false, isRecovered: false, reason: null, detail: null, unfinishedTails: 0 };
for (const scenario of ["nonzero", "partial", "duplicate", "extra", "invalidUTF8", "missing", "oversized", "stderr"]) test(`client refuses ${scenario} output and reaps only its worker`, async (t) => {
	const bytes = JSON.stringify(protocolFinal) + "\n";
	const statements: Record<string, string> = {
		nonzero: `process.stdout.write(${JSON.stringify(bytes)}); process.exitCode=1;`,
		partial: `process.stdout.write(${JSON.stringify(bytes.slice(0, -1))});`,
		duplicate: `process.stdout.write(${JSON.stringify(bytes + bytes)});`,
		extra: `process.stdout.write(${JSON.stringify(bytes + "{}")} );`,
		invalidUTF8: "process.stdout.write(Buffer.from([255,10]));",
		missing: "",
		oversized: `const part=Buffer.alloc(1048576,120); for(let i=0;i<194;i++)process.stdout.write(part);`,
		stderr: `process.stderr.write('x'.repeat(8193)); process.stdout.write(${JSON.stringify(bytes)});`,
	};
	await scriptedWorker(t, `process.stdin.once('data',()=>{${statements[scenario]} process.stdin.destroy();});`);
	await assert.rejects(dream.runDreamWorker(protocolStart, async () => { assert.fail("No request authorized"); }, new AbortController().signal));
});

test("client failure keeps the worker exit and stderr cause", async (t) => {
	await scriptedWorker(t, "process.stdin.once('data',()=>{process.stderr.write('dream-worker: dream storage limit exceeded'); process.exitCode=1; process.stdin.destroy();});");
	await assert.rejects(dream.runDreamWorker(protocolStart, async () => { assert.fail("No request"); }, new AbortController().signal), { message: "Dream worker exited (code 1) without a final report · stderr: dream-worker: dream storage limit exceeded" });
});

test("client keeps a failed model call as the pending report cause", async (t) => {
	const request = { version: 1, type: "modelRequest", invocationID: "invocation", requestID: "run:" + "a".repeat(64), runID: "run", generation: "3", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection: protocolStart.selection, systemPrompt: "saved", messages: [{ role: "user", text: "text", timestampMilliseconds: 0 }] };
	const pending = { ...protocolFinal, status: "pending", generation: "3", runID: "run", base: "b".repeat(40), reason: "callbackFailure" };
	await scriptedWorker(t, `let count = 0; process.stdin.on('data',()=>{ if (count++ === 0) process.stdout.write(${JSON.stringify(JSON.stringify(request) + "\n")}); else { process.stdout.write(${JSON.stringify(JSON.stringify(pending) + "\n")}); process.stdin.destroy(); } });`);
	const report = await dream.runDreamWorker(protocolStart, async () => { throw new Error("provider quota exceeded"); }, new AbortController().signal);
	assert.equal(report.detail, "Model call: provider quota exceeded");
});

test("dream all runs every batch until the backlog ends", async (t) => {
	const f = await fixture(t);
	const counter = join(f.root, "starts.txt");
	await writeFile(counter, "0");
	await scriptedWorker(t, `const fs = require("node:fs"); process.stdin.once("data", bytes => {
const start = JSON.parse(bytes.toString());
const count = Number(fs.readFileSync(${JSON.stringify(counter)}, "utf8")) + 1; fs.writeFileSync(${JSON.stringify(counter)}, String(count));
if (start.batchTextBytes !== 262144) process.exit(9);
process.stdout.write(JSON.stringify({ version: 1, type: "final", invocationID: start.invocationID, status: "completed", generation: String(count), runID: "run", base: "b".repeat(40), proposals: [], notes: [], isBacklog: count < 13, isRecovered: false, reason: null, detail: null, unfinishedTails: 0 }) + "\\n"); process.stdin.destroy();
});`);
	let handler!: (args: string, ctx: import("@earendil-works/pi-coding-agent").ExtensionCommandContext) => Promise<void>;
	const entries: unknown[] = [];
	const shutdown = dream.registerDream({ registerCommand: (_name: string, command: { handler: typeof handler }) => { handler = command.handler; }, registerEntryRenderer: () => {}, appendEntry: (_name: string, data: unknown) => entries.push(data), getThinkingLevel: () => "medium" } as unknown as ExtensionAPI);
	await handler("all", { mode: "rpc", cwd: f.root, model: { provider: "openai", id: "gpt-6.1", contextWindow: 262_144 }, waitForIdle: async () => {}, ui: { notify: () => {} } } as unknown as import("@earendil-works/pi-coding-agent").ExtensionCommandContext);
	assert.equal(entries.length, 13); await shutdown();
});

test("client rejects duplicate or wrong-bound requests before a second registry call", async (t) => {
	const request = { version: 1, type: "modelRequest", invocationID: "invocation", requestID: "run:" + "a".repeat(64), runID: "run", generation: "0", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection: protocolStart.selection, systemPrompt: "saved", messages: [{ role: "user", text: "café 🌱", timestampMilliseconds: 0 }] };
	const bytes = JSON.stringify(request) + "\n";
	await scriptedWorker(t, `process.stdin.once('data',()=>{process.stdout.write(${JSON.stringify(bytes + bytes)});process.stdin.destroy();});`);
	let calls = 0;
	await assert.rejects(dream.runDreamWorker(protocolStart, async () => { calls++; return "{}"; }, new AbortController().signal));
	assert.equal(calls, 1);
});

test("client accepts a valid fragmented final only after zero exit", async (t) => {
	await scriptedWorker(t, `process.stdin.once('data',()=>{for(const byte of Buffer.from(${JSON.stringify(JSON.stringify(protocolFinal) + "\n")}))process.stdout.write(Buffer.from([byte]));process.stdin.destroy();});`);
	assert.deepEqual(await dream.runDreamWorker(protocolStart, async () => { assert.fail("No request"); }, new AbortController().signal), protocolFinal);
});

test("client cancellation terminates and reaps an unresponsive worker", async (t) => {
	await scriptedWorker(t, "process.on('SIGTERM',()=>{}); process.stdin.resume(); setInterval(()=>{},1000);");
	const controller = new AbortController(); const before = performance.now();
	const work = dream.runDreamWorker(protocolStart, async () => { assert.fail("No request"); }, controller.signal);
	setTimeout(() => controller.abort(), 20);
	await assert.rejects(work); assert.ok(performance.now() - before < 3500);
});

test("live coverage commits only after success and retry keeps frozen bytes when new records arrive", async (t) => {
	const f = await fixture(t);
	const bytes = Buffer.byteLength("Use green buttons, café 🌱, not blue.");
	const firstFrames: DreamCoverage[] = [];
	const first = await dream.runDreamWorker(f.start, async () => { throw new Error("interrupted"); }, new AbortController().signal, (frame) => firstFrames.push(frame));
	assert.equal(first.status, "pending");
	assert.deepEqual(firstFrames.map((frame) => [frame.backlogBytes, frame.plannedBytes, frame.completedBytes, frame.undreamtBytes, frame.nextBytes]), [[bytes, bytes, 0, bytes, 0]]);
	const extra = JSON.stringify({ type: "message", id: "extra", parentId: "entry", timestamp: "1999-01-01T00:00:00.000Z", message: { role: "user", content: "Prefer small buttons." } }) + "\n";
	await writeFile(f.sessionFile, await readFile(f.sessionFile, "utf8") + extra);
	const inspectFrames: DreamCoverage[] = [];
	const inspected = await dream.runDreamWorker(f.start, async () => { assert.fail("Inspection must not repeat the call"); }, new AbortController().signal, (frame) => inspectFrames.push(frame));
	assert.equal(inspected.status, "pending");
	assert.equal(inspectFrames[0].repeatedRecords, 1);
	assert.equal(inspectFrames[0].completedBytes, 0);
	await rm(f.roots.sessions, { recursive: true });
	const retryFrames: DreamCoverage[] = [];
	const retry = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, async (request) => decision(request), new AbortController().signal, (frame) => retryFrames.push(frame));
	assert.equal(retry.status, "completed");
	assert.deepEqual(retryFrames.map((frame) => [frame.backlogBytes, frame.plannedBytes, frame.completedBytes, frame.undreamtBytes, frame.nextBytes, frame.repeatedRecords]), [[null, bytes, 0, null, null, 1], [null, bytes, bytes, null, null, 1]]);
	assert.equal(retryFrames[0].estimateSeconds, null);
	const timing = JSON.parse(await readFile(join(f.roots.state, "timing.json"), "utf8"));
	assert.ok(timing.seconds > 0); assert.equal(timing.records, 2); assert.equal(timing.inputBytes, bytes);
});

test("later equal-size batch uses measured successful model time as an explicit estimate", async (t) => {
	const f = await fixture(t);
	await dream.runDreamWorker(f.start, async (request) => decision(request), new AbortController().signal);
	const records = (await readFile(f.sessionFile, "utf8")).replace("synthetic-session", "alternate-session");
	assert.equal(Buffer.byteLength(records), (await readFile(f.sessionFile)).length);
	await writeFile(join(f.roots.sessions, "synthetic-project", "second.jsonl"), records);
	const frames: DreamCoverage[] = [];
	const report = await dream.runDreamWorker(f.start, async (request) => decision(request), new AbortController().signal, (frame) => frames.push(frame));
	assert.equal(report.status, "completed");
	assert.ok(frames[0].estimateSeconds! > 0);
	assert.match(dream.dreamProgressText(frames[0], 0, "model call"), /estimate ~\d+s/);
});

test("transport rejects progress completion followed by an uncommitted final report", async (t) => {
	const frame = { version: 1, type: "progress", invocationID: protocolStart.invocationID, backlogBytes: 100, backlogLimitBytes: 400, plannedBytes: 100, completedBytes: 0, undreamtBytes: 100, nextBytes: 0, repeatedRecords: 0, estimateSeconds: null };
	const output = [frame, { ...frame, completedBytes: 100 }, protocolFinal].map((value) => JSON.stringify(value) + "\n").join("");
	await scriptedWorker(t, `process.stdout.write(${JSON.stringify(output)});`);
	await assert.rejects(dream.runDreamWorker(protocolStart, async () => { assert.fail("No model request"); }, new AbortController().signal));
});

for (const ending of ["completed", "pending", "blocked", "busy", "noNewRecords", "error", "cancel", "shutdown"] as const) test(`dream all saves reports in order and stops on ${ending} without retry or approval`, async (t) => {
	const f = await fixture(t);
	const startsFile = join(f.root, "starts.json");
	const entriesFile = join(f.root, "entries.json");
	await writeFile(startsFile, "[]"); await writeFile(entriesFile, "[]");
	await scriptedWorker(t, `
const fs = require("node:fs");
process.stdin.once("data", bytes => {
 const start = JSON.parse(bytes.toString());
 const starts = JSON.parse(fs.readFileSync(${JSON.stringify(startsFile)}, "utf8"));
 const entries = JSON.parse(fs.readFileSync(${JSON.stringify(entriesFile)}, "utf8"));
 if (entries.length !== starts.length) process.exit(9);
 starts.push(start); fs.writeFileSync(${JSON.stringify(startsFile)}, JSON.stringify(starts));
 if (starts.length > 1 && ${JSON.stringify(ending)} === "error") process.exit(1);
 const status = starts.length === 1 ? "completed" : ${JSON.stringify(ending === "cancel" || ending === "shutdown" ? "completed" : ending)};
 const report = { version: 1, type: "final", invocationID: start.invocationID, status, generation: String(starts.length), runID: ["busy", "noNewRecords"].includes(status) ? null : "run", base: ["busy", "noNewRecords"].includes(status) ? null : "b".repeat(40), proposals: [], notes: [], isBacklog: starts.length === 1 || status !== "completed", isRecovered: starts.length === 1, reason: null, detail: null, unfinishedTails: 0 };
 const progress = { version: 1, type: "progress", invocationID: start.invocationID, backlogBytes: 200, backlogLimitBytes: 400, plannedBytes: 100, completedBytes: 0, undreamtBytes: starts.length === 1 ? 200 : 100, nextBytes: starts.length === 1 ? 100 : 0, repeatedRecords: 0, estimateSeconds: null };
 if (status === "completed") process.stdout.write(JSON.stringify(progress) + "\\n");
 setTimeout(() => {
  if (status === "completed") process.stdout.write(JSON.stringify({ ...progress, completedBytes: 100 }) + "\\n");
  process.stdout.write(JSON.stringify(report) + "\\n"); process.stdin.destroy();
 }, 100);
});`);
	let handler!: (args: string, ctx: import("@earendil-works/pi-coding-agent").ExtensionCommandContext) => Promise<void>;
	const entries: unknown[] = []; const notices: string[] = [];
	const frames: string[][] = [];
	let shutdown!: () => Promise<void>; let loader: { handleInput(value: string): void; dispose(): void; render(width: number): string[] } | undefined;
	shutdown = dream.registerDream({
		registerCommand: (_name: string, command: { handler: typeof handler }) => { handler = command.handler; },
		registerEntryRenderer: () => {}, getThinkingLevel: () => "medium",
		appendEntry: (_name: string, value: unknown) => {
			entries.push(value); writeFileSync(entriesFile, JSON.stringify(entries));
			if (ending === "cancel") loader!.handleInput("\u001b");
			if (ending === "shutdown") void shutdown();
		},
	} as unknown as ExtensionAPI);
	const captured = { provider: "openai", id: "gpt-6.1", api: "openai-responses", contextWindow: 262_144 };
	let modelReads = 0; let thinkingReads = 0;
	const ctx = {
		mode: "tui", cwd: f.root,
		get model() { modelReads++; return modelReads === 1 ? captured : { ...captured, id: "changed" }; },
		get thinkingLevel() { thinkingReads++; return thinkingReads === 1 ? "medium" : "high"; },
		waitForIdle: async () => {},
		modelRegistry: { streamSimple: () => assert.fail("No provider call or retry allowed") },
		ui: { notify: (value: string) => notices.push(value), custom: (factory: (...args: unknown[]) => unknown) => new Promise((done) => {
			loader = factory({ requestRender: () => { if (loader) frames.push(loader.render(100)); } }, { fg: (_name: string, value: string) => value }, {}, done) as typeof loader;
		}) },
	} as unknown as import("@earendil-works/pi-coding-agent").ExtensionCommandContext;
	await handler("all", ctx); loader?.dispose(); await shutdown();
	const starts = JSON.parse(await readFile(startsFile, "utf8")) as DreamStart[];
	assert.equal(starts.length, ending === "cancel" || ending === "shutdown" ? 1 : 2);
	assert.equal(entries.length, ending === "error" || ending === "cancel" || ending === "shutdown" ? 1 : 2);
	assert.equal(modelReads, 1); assert.equal(thinkingReads, 1);
	assert.equal(new Set(starts.map((start) => start.invocationID)).size, starts.length);
	for (const start of starts) {
		assert.deepEqual(start.selection, { provider: "openai", modelID: "gpt-6.1", thinkingLevel: "medium" });
		assert.equal(start.resume, "inspectOrContinue");
	}
	if (ending === "error") assert.match(notices.join("\n"), /Dream failed/);
	if (ending === "completed") {
		assert.ok(frames.some((frame) => frame.join("\n").includes("all · batch 1")));
		assert.ok(frames.some((frame) => frame.join("\n").includes("all · batch 2")));
		if (process.env.DREAM_VISUAL_EVIDENCE) await writeFile(process.env.DREAM_VISUAL_EVIDENCE, JSON.stringify(frames));
	}
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), "# Memory\n");
});

for (const argument of ["", "retry"]) test(`dream ${argument || "default"} remains one batch with backlog`, async (t) => {
	const f = await fixture(t);
	await scriptedWorker(t, `process.stdin.once("data", bytes => {
const start = JSON.parse(bytes.toString());
if (start.resume !== ${JSON.stringify(argument === "retry" ? "retryInterruptedCall" : "inspectOrContinue")}) process.exit(9);
process.stdout.write(JSON.stringify({ version: 1, type: "final", invocationID: start.invocationID, status: "completed", generation: "1", runID: "run", base: "b".repeat(40), proposals: [], notes: [], isBacklog: true, isRecovered: false, reason: null, detail: null, unfinishedTails: 0 }) + "\\n"); process.stdin.destroy();
});`);
	let handler!: (args: string, ctx: import("@earendil-works/pi-coding-agent").ExtensionCommandContext) => Promise<void>;
	const entries: unknown[] = [];
	const shutdown = dream.registerDream({ registerCommand: (_name: string, command: { handler: typeof handler }) => { handler = command.handler; }, registerEntryRenderer: () => {}, appendEntry: (_name: string, data: unknown) => entries.push(data), getThinkingLevel: () => "medium" } as unknown as ExtensionAPI);
	await handler(argument, { mode: "rpc", cwd: f.root, model: { provider: "openai", id: "gpt-6.1", contextWindow: 262_144 }, waitForIdle: async () => {}, ui: { notify: () => {} } } as unknown as import("@earendil-works/pi-coding-agent").ExtensionCommandContext);
	assert.equal(entries.length, 1); await shutdown();
});
