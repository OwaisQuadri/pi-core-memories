import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test, type TestContext } from "node:test";
import type { AssistantMessage, Context, Model } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { DreamCoverage, DreamRequest, DreamStart } from "./dream.ts";
type RegistryFixture = Pick<ExtensionContext["modelRegistry"], "streamSimple">;
const subscription = { isUsingOAuth: () => true, getProvider: () => ({ auth: { oauth: { isSubscription: true } } }) };

import { sdkURL, aiURL } from "./test/host.ts";
const nativeDream = await import("./dream.ts");
const { protectDreamSources, sourceProtectionDigest } = await import("./source-protection.ts");
const { sourceProtectionFixture } = await import("./test/source-protection.ts");
const dream = {
	...nativeDream,
	runDreamWorker: (...args: Parameters<typeof nativeDream.runDreamWorker>) => nativeDream.runDreamWorker(args[0], args[1], args[2], args[3], args[4] ?? ((value, signal) => protectDreamSources(sourceProtectionFixture(), args[0].invocationID, value, signal))),
};
const sdk = await import(sdkURL) as typeof import("@earendil-works/pi-coding-agent");
const ai = await import(aiURL) as typeof import("@earendil-works/pi-ai");
const binary = process.env.PI_CORE_MEMORIES_BIN ?? process.env.PI_CORE_MEMORIES_EXECUTABLE;
assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the verified release command");

async function fixture(t: TestContext, isPrimary = true) {
	const root = await mkdtemp("/private/tmp/pi-dream-adapter-");
	const home = join(root, "home"); const agent = join(home, "agent"); const repo = join(root, "memory ' ; $repo"); const bin = join(root, "bin");
	const previous = Object.fromEntries(["HOME", "PI_CORE_MEMORIES_EXECUTABLE", "PI_CORE_MEMORIES_REPO", "PI_CODING_AGENT_DIR"].map((name) => [name, process.env[name]]));
	const previousFetch = globalThis.fetch; let networkCalls = 0;
	globalThis.fetch = async () => { networkCalls++; throw new Error("Network forbidden"); };
	t.after(async () => {
		globalThis.fetch = previousFetch;
		for (const [name, value] of Object.entries(previous)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
		await rm(root, { recursive: true, force: true }); assert.equal(networkCalls, 0);
	});
	await mkdir(agent, { recursive: true });
	process.env.HOME = home; process.env.PI_CODING_AGENT_DIR = agent; process.env.PI_CORE_MEMORIES_REPO = repo; process.env.PI_CORE_MEMORIES_EXECUTABLE = resolve(binary!);
	const cli = (...args: string[]) => execFileSync(binary!, args, { encoding: "utf8" });
	cli("init", "--repo", repo);
	const folder = join(agent, "sessions", "synthetic-project"); await mkdir(folder, { recursive: true });
	const sessionFile = join(folder, "synthetic.jsonl");
	await writeFile(sessionFile, [
		{ type: "session", version: 3, id: "synthetic-session", timestamp: "1999-01-01T00:00:00.000Z", cwd: root },
		...(isPrimary ? [{ type: "message", id: "entry", parentId: null, timestamp: "1999-01-01T00:00:00.000Z", message: { role: "user", content: "Use green buttons, café 🌱, not blue.", timestamp: 0 } }] : []),
	].map((entry) => JSON.stringify(entry) + "\n").join(""));
	const roots = await dream.dreamRoots(agent, root);
	const selection = { provider: "openai", modelID: "selected", thinkingLevel: "off" };
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
		const recovered = await dream.runDreamWorker({ ...f.start, selection: { provider: "anthropic", modelID: "other", thinkingLevel: "high" }, resume: "retryInterruptedCall" }, forbidden, new AbortController().signal);
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

test("real worker reports the provider's error cause but never its response, saves no response, and calls again only on explicit retry", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined; let calls = 0;
	const model = { provider: f.start.selection.provider, id: f.start.selection.modelID, api: "offline" } as Parameters<typeof dream.callDreamModel>[2];
	const memoryBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
	const report = await dream.runDreamWorker(f.start, async (request, signal) => {
		saved = request;
		const registry = { streamSimple(current) {
			calls++;
			const reply: AssistantMessage = { role: "assistant", api: current.api, provider: current.provider, model: current.id, content: [{ type: "text", text: "PRIVATE PARTIAL RESPONSE" }], stopReason: "error", errorMessage: "fixture provider quota exceeded", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
			const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "error", reason: "error", error: reply }); return stream;
		} } satisfies RegistryFixture;
		return dream.callDreamModel(request, { modelRegistry: { ...subscription, ...registry } as unknown as Parameters<typeof dream.callDreamModel>[1]["modelRegistry"] }, model, f.start.selection, signal);
	}, new AbortController().signal);
	assert.equal(report.status, "pending"); assert.equal(report.reason, "callbackFailure"); assert.equal(report.generation, "0"); assert.equal(calls, 1);
	assert.equal(report.detail, "Dream model call failed: error: fixture provider quota exceeded");
	const display = dream.dreamReviewText(report);
	assert.ok(display.includes(`Cause: ${report.detail}`)); assert.ok(display.includes("Discuss recovery in conversation before another model call.")); assert.ok(!display.includes("/dream")); assert.ok(!display.includes("PRIVATE PARTIAL RESPONSE"));
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
	const changed = await dream.runDreamWorker({ ...start, selection: { provider: "anthropic", modelID: "changed", thinkingLevel: "high" } }, async () => { assert.fail("Saved response cannot be replaced"); }, new AbortController().signal);
	assert.equal(changed.status, "pending"); assert.equal(changed.reason, "invalidDecision"); assert.equal(changed.detail, first.detail);
	const replacement = await dream.runDreamWorker({ ...start, resume: "replaceInvalidResponse" }, async (request) => {
		const context = JSON.parse(request.messages[0].text) as { primaryEvidence: { source: unknown }[]; ownerAnchorsNotPrimaryEvidence: Record<string, unknown>[] };
		return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: [{ kind: "ownerNote", sources: [context.primaryEvidence[0].source], owner: context.ownerAnchorsNotPrimaryEvidence[0], contradictions: [], explanation: "The owner contains the rule." }] });
	}, new AbortController().signal);
	assert.equal(replacement.status, "completed"); assert.equal(replacement.generation, "1"); assert.equal(replacement.runID, first.runID); assert.equal(replacement.notes[0].kind, "ownerNote");
	const directory = join(start.roots.state, "runs", first.runID!);
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), await readFile(join(directory, "response.json")));
});

test("explicit worker replacement alone dispatches current selection and archives rejected bytes", async (t) => {
	const f = await fixture(t);
	const calls: { model: unknown; context: Context; reasoning: unknown }[] = [];
	const selectedModel: Model<"offline"> = { provider: "openai", id: "selected", api: "offline", name: "Synthetic model", baseUrl: "https://offline.invalid", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262_144, maxTokens: 16_384 };
	const current = { ...selectedModel, provider: "anthropic", id: "current" };
	const registry = { streamSimple(model, context, options) {
		calls.push({ model, context, reasoning: options?.reasoning });
		const payload = JSON.parse(context.messages[0].content as string) as { contextHash: string; primaryEvidence: { source: unknown }[] };
		const text = calls.length === 1 ? " \nInvalid café 🌱 reply\r\n " : JSON.stringify({ schemaVersion: 1, contextHash: payload.contextHash, decisions: payload.primaryEvidence.map((entry) => ({ kind: "noChange", sources: [entry.source], reasonCode: "notDurable", explanation: "Offline replacement." })) });
		const reply: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id, content: [{ type: "text", text }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
		const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "done", reason: "stop", message: reply }); stream.end(reply); return stream;
	} } satisfies RegistryFixture;
	const ctx = { cwd: f.root, mode: "rpc", model: selectedModel, thinkingLevel: "off", waitForIdle: async () => {}, ui: { notify: () => {} }, modelRegistry: { ...subscription, ...registry } };
	const launch = (start: DreamStart) => dream.runDreamWorker(start, (request, signal) => dream.callDreamModel(request, ctx as unknown as import("@earendil-works/pi-coding-agent").ExtensionContext, ctx.model, start.selection, signal), new AbortController().signal);
	const memoryBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
	const first = await launch(f.start);
	assert.equal(first.reason, "invalidDecision"); assert.equal(calls.length, 1);
	const runID = first.runID!;
	const directory = join(f.roots.state, "runs", runID);
	const original = await readFile(join(directory, "response.json"));
	const names = ["input.json", "context.json", "request.json"];
	const frozen = await Promise.all(names.map((name) => readFile(join(directory, name))));
	for (const resume of ["inspectOrContinue", "retryInterruptedCall"] as const) {
		assert.equal((await launch({ ...f.start, resume })).reason, "invalidDecision"); assert.equal(calls.length, 1);
	}
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
	await rm(f.roots.sessions, { recursive: true });
	ctx.model = current; ctx.thinkingLevel = "high";
	const currentStart: DreamStart = { ...f.start, selection: { provider: current.provider, modelID: current.id, thinkingLevel: "high" }, resume: "replaceInvalidResponse" };
	const replaced = await launch(currentStart);
	assert.equal(calls.length, 2); assert.strictEqual(calls[1].model, current); assert.equal(calls[1].reasoning, "high"); assert.deepEqual(calls[1].context, calls[0].context);
	assert.equal(replaced.status, "completed"); assert.equal(replaced.runID, runID); assert.equal(replaced.generation, "1");
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), original);
	assert.deepEqual(await readFile(join(directory, "response.json")), original);
	assert.deepEqual(await Promise.all(names.map((name) => readFile(join(directory, name)))), frozen);
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
	assert.equal((await launch(currentStart)).status, "blocked"); assert.equal(calls.length, 2);
});

test("interrupted replacement needs explicit retry, retains original, and retries only under its recorded selection", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined;
	const first = await dream.runDreamWorker(f.start, async (request) => { saved = request; return "Invalid café 🌱"; }, new AbortController().signal);
	assert.equal(first.reason, "invalidDecision");
	const directory = join(f.roots.state, "runs", saved!.runID);
	const original = await readFile(join(directory, "response.json"));
	const replacing: DreamStart = { ...f.start, resume: "replaceInvalidResponse", selection: { provider: "anthropic", modelID: "current", thinkingLevel: "high" } };
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
	const other: DreamStart = { ...replacing, resume: "retryInterruptedCall", selection: { provider: "third", modelID: "latest", thinkingLevel: "medium" } };
	const refused = await dream.runDreamWorker(other, forbidden, new AbortController().signal);
	assert.equal(refused.status, "pending"); assert.equal(refused.reason, "interruptedCall"); assert.deepEqual(refused.callSelection, replacing.selection);
	const retry: DreamStart = { ...replacing, resume: "retryInterruptedCall" };
	const completed = await dream.runDreamWorker(retry, async (request) => {
		assert.deepEqual(request, { ...saved, selection: replacing.selection }); return decision(request);
	}, new AbortController().signal);
	assert.equal(completed.status, "completed"); assert.equal(completed.generation, "1"); assert.equal(completed.runID, saved!.runID);
	assert.deepEqual(await readFile(join(directory, "response.json")), original);
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), original);
	const replay = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, forbidden, new AbortController().signal);
	assert.equal(replay.status, "completed"); assert.equal(replay.runID, saved!.runID);
});

test("resumed worker dispatches its recorded provider, model and thinking with exact frozen context", async (t) => {
	for (const selection of [
		{ provider: "anthropic", modelID: "selected", thinkingLevel: "off" },
		{ provider: "openai", modelID: "other", thinkingLevel: "off" },
		{ provider: "openai", modelID: "selected", thinkingLevel: "high" },
	]) {
		const f = await fixture(t); let saved: DreamRequest | undefined;
		const first = await dream.runDreamWorker({ ...f.start, selection }, async (request) => { saved = request; throw new Error("interrupted"); }, new AbortController().signal);
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
			} } satisfies RegistryFixture;
			return dream.callDreamModel(request, { modelRegistry: { ...subscription, ...registry } as unknown as Parameters<typeof dream.callDreamModel>[1]["modelRegistry"] }, model, selection, signal);
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

test("SDK custom virtual transport never receives a subscription-only request", async (t) => {
	const f = await fixture(t);
	const runtime = await sdk.ModelRuntime.create({ authPath: join(f.agent, "auth.json"), modelsPath: null, modelsStorePath: join(f.agent, "models.json"), allowModelNetwork: false, refreshOnCreate: false });
	const baseline = runtime.getModels("openai").find((item) => item.reasoning); assert.ok(baseline);
	const native: Model<"offline-native-api"> = { provider: "offline-native", id: "physical", name: "Offline physical model", api: "offline-native-api", baseUrl: "https://fixture.invalid", reasoning: true, input: ["text"], cost: { ...baseline.cost }, contextWindow: baseline.contextWindow, maxTokens: baseline.maxTokens };
	let nativeCalls = 0; let routes = 0;
	const scripted: typeof runtime.streamSimple = () => {
		nativeCalls++; throw new Error("Custom transport must not receive subscription-only requests");
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
	await assert.rejects(dream.callDreamModel(request, { modelRegistry: registry }, captured, selection, new AbortController().signal), /the selected model is not using a subscription sign-in; nothing was dispatched/);
	assert.equal(routes, 0); assert.equal(nativeCalls, 0); assert.equal(captured.api, "pi-virtual"); assert.equal(request.selection.thinkingLevel, "medium");
});

function contentHash(context: Context): string {
	const payload = JSON.parse(typeof context.messages[0].content === "string" ? context.messages[0].content : "") as Record<string, unknown>;
	assert.equal(typeof payload.contextHash, "string");
	return payload.contextHash as string;
}

async function scriptedWorker(t: TestContext, script: string, isProtected = false): Promise<void> {
	const root = await mkdtemp("/private/tmp/dream-protocol-"); const old = process.env.PI_CORE_MEMORIES_EXECUTABLE;
	t.after(async () => { if (old === undefined) delete process.env.PI_CORE_MEMORIES_EXECUTABLE; else process.env.PI_CORE_MEMORIES_EXECUTABLE = old; await rm(root, { recursive: true, force: true }); });
	const protection = { version: 1, type: "sourceProtectionRequest", invocationID: "invocation", requestID: "fixture-source", inputDigest: sourceProtectionDigest(["safe fixture"]), pieces: ["safe fixture"] };
	const body = isProtected ? `let initial; function protect(bytes) { if (!initial) { initial = bytes; process.stdout.write(JSON.stringify(${JSON.stringify(protection)}) + '\\n'); } else { process.stdin.off('data', protect); ${script}; process.stdin.emit('data', initial); } } process.stdin.on('data', protect);` : script;
	await writeFile(join(root, "pi-core-memories"), `#!${process.execPath}\nif (process.argv[2] === "scope") { process.stdout.write(JSON.stringify({ deviceKey: null, projectBindings: {} }) + "\\n"); process.exit(0); }\n${body}\n`, { mode: 0o755 }); await chmod(join(root, "pi-core-memories"), 0o755);
	process.env.PI_CORE_MEMORIES_EXECUTABLE = join(root, "pi-core-memories");
}
const protocolStart: DreamStart = { version: 1, type: "start", invocationID: "invocation", roots: { state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }, selection: { provider: "openai", modelID: "selected", thinkingLevel: "off" }, resume: "inspectOrContinue", batchTextBytes: 262_144 };
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
	await scriptedWorker(t, `let count = 0; process.stdin.on('data',()=>{ if (count++ === 0) process.stdout.write(${JSON.stringify(JSON.stringify(request) + "\n")}); else { process.stdout.write(${JSON.stringify(JSON.stringify(pending) + "\n")}); process.stdin.destroy(); } });`, true);
	const report = await dream.runDreamWorker(protocolStart, async () => { throw new Error("provider quota exceeded"); }, new AbortController().signal);
	assert.equal(report.detail, "The dream model call did not complete.");
});

test("client rejects duplicate or wrong-bound requests before a second registry call", async (t) => {
	const request = { version: 1, type: "modelRequest", invocationID: "invocation", requestID: "run:" + "a".repeat(64), runID: "run", generation: "0", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection: protocolStart.selection, systemPrompt: "saved", messages: [{ role: "user", text: "café 🌱", timestampMilliseconds: 0 }] };
	const bytes = JSON.stringify(request) + "\n";
	await scriptedWorker(t, `process.stdin.once('data',()=>{process.stdout.write(${JSON.stringify(bytes + bytes)});process.stdin.destroy();});`, true);
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
