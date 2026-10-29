import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import type { AssistantMessage, AssistantMessageEvent, Context } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { DreamRequest, DreamSelection, DreamStart } from "./dream.ts";
type SubscriptionSimpleStreamOptions = NonNullable<Parameters<ExtensionContext["modelRegistry"]["streamSimple"]>[2]> & { onDispatch?: (physical: { provider: string; modelID: string; api: string }) => void };

import { tuiURL } from "./test/host.ts";
const dream = await import("./dream.ts");
const { default: coreMemories } = await import("./index.ts");
const tui = await import(tuiURL) as typeof import("@earendil-works/pi-tui");
const selection: DreamSelection = { provider: "openai", modelID: "selected", thinkingLevel: "off" };
const start: DreamStart = { version: 1, type: "start", invocationID: "invocation", roots: { state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }, selection, resume: "inspectOrContinue", batchTextBytes: 262_144 };
const request: DreamRequest = { version: 1, type: "modelRequest", invocationID: "invocation", requestID: "run:" + "a".repeat(64), runID: "run", generation: "0", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection, systemPrompt: "EXACT pinned system 🌱", messages: [{ role: "user", text: "saved exact\ninput café", timestampMilliseconds: 0 }] };
const final = { version: 1, type: "final", invocationID: "invocation", status: "noNewRecords", generation: "0", runID: null, base: null, proposals: [], notes: [], isBacklog: false, isRecovered: false, reason: null, detail: null, unfinishedTails: 0 };
const model = { provider: "openai", id: "selected", api: "openai-responses" } as NonNullable<ExtensionContext["model"]>;
function message(change: Partial<AssistantMessage> = {}): AssistantMessage {
	return { role: "assistant", provider: selection.provider, model: selection.modelID, api: "openai-responses", content: [{ type: "text", text: " {" }, { type: "thinking", thinking: "not decision JSON" }, { type: "text", text: "🌱} \n" }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, ...change };
}
function registry(events: AssistantMessageEvent[], result = message()) {
	const calls: { model: unknown; context: Context; options: unknown }[] = [];
	const ctx = { modelRegistry: { streamSubscriptionSimple(current: typeof model, context: Context, options: SubscriptionSimpleStreamOptions) {
		calls.push({ model: current, context, options });
		options.onDispatch?.(Object.freeze({ provider: current.provider, modelID: current.id, api: current.api }));
		return { async *[Symbol.asyncIterator]() { yield* events; }, result: async () => result };
	} } } as unknown as ExtensionContext;
	return { ctx, calls };
}

test("invalid saved decision explains retained recovery in conversation without commands", () => {
	const detail = 'decision(index: 5, category: "owner anchor bytes do not match pinned slice")';
	const report = dream.dreamReport({ ...final, status: "pending", runID: "run", base: "b".repeat(40), reason: "invalidDecision", detail }, start);
	const output = dream.dreamReviewText(report);
	assert.ok(output.includes("The saved model reply failed validation."));
	assert.ok(output.includes(`Cause: ${detail}`));
	assert.ok(output.includes("Memory was not changed. The saved reply did not pass validation."));
	assert.ok(output.includes("Discuss the retained work in conversation before requesting a replacement model call."));
	assert.ok(!output.includes("/dream"));
	assert.ok(dream.dreamReviewText({ ...report, reason: "interruptedCall" }).includes("Discuss recovery in conversation"));
});

test("subscription registry receives only pinned bytes and timestamps, captured model, and transport-only off mapping", async () => {
	for (const level of ["off", "medium"]) {
		const captured = { ...selection, thinkingLevel: level };
		const f = registry([{ type: "done", reason: "stop", message: message() }]);
		const signal = new AbortController().signal;
		assert.equal(await dream.callDreamModel({ ...request, selection: captured }, f.ctx, model, captured, signal), " {🌱} \n");
		assert.equal(f.calls.length, 1); assert.strictEqual(f.calls[0].model, model);
		assert.deepEqual(f.calls[0].context, { systemPrompt: request.systemPrompt, messages: [{ role: "user", content: request.messages[0].text, timestamp: 0 }] });
		assert.deepEqual(Object.keys(f.calls[0].options as object).sort(), ["onDispatch", "reasoning", "signal"]);
		assert.equal((f.calls[0].options as { reasoning?: string }).reasoning, level === "off" ? undefined : level);
		assert.equal(request.selection.thinkingLevel, "off");
	}
});

const incompleteCauses = {
	length: "response reached the output token limit", toolUse: "unexpected tool call", error: "provider error (no error message)",
	aborted: "provider aborted the response (no error message)", pending: "response is pending", deferred: "response was deferred",
};
for (const reason of ["length", "toolUse", "error", "aborted", "pending", "deferred"] as const) test(`registry explains ${reason} terminal and final failures without accepting incomplete text`, async () => {
	const reply = message({ stopReason: reason });
	const event = reason === "error" || reason === "aborted" ? { type: "error", reason, error: reply } : { type: "done", reason, message: reply };
	for (const events of [[event as AssistantMessageEvent], [{ type: "done", reason: "stop", message: message() } as AssistantMessageEvent]]) {
		const f = registry(events, reply);
		await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), { message: `Dream model call failed: ${incompleteCauses[reason]}` });
	}
});

test("provider error events retain only bounded errorMessage, not response content or payload fields", async () => {
	const forbidden = new Proxy([], { get: () => assert.fail("Error content must not be inspected"), ownKeys: () => assert.fail("Error content must not be serialized") });
	for (const reason of ["error", "aborted"] as const) {
		const reply = message({ stopReason: reason, errorMessage: "fixture quota exceeded", content: forbidden });
		for (const events of [[{ type: "error", reason, error: reply }], [{ type: "done", reason: "stop", message: message() }]] as AssistantMessageEvent[][]) {
			const f = registry(events, reply);
			await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), { message: `Dream model call failed: ${reason === "error" ? "provider error" : "provider aborted the response"}: fixture quota exceeded` });
		}
	}
	const reply = message({ stopReason: "error", errorMessage: "fixture failure\0\u001b[31m\u202e" + "🌱".repeat(1000) + "OMITTED", content: forbidden });
	const f = registry([{ type: "error", reason: "error", error: reply }], reply);
	await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), (error: Error) => {
		assert.ok(Buffer.byteLength(error.message) < 1000);
		assert.ok(error.message.startsWith("Dream model call failed: provider error: fixture failure\\u{0}\\u{1B}[31m\\u{202E}"));
		assert.ok(!error.message.includes("OMITTED"));
		const report = dream.dreamReport({ ...final, status: "pending", runID: "run", base: "b".repeat(40), reason: "callbackFailure", detail: `Model call: ${error.message}` }, start);
		assert.ok(dream.dreamReviewText(report).includes(`Cause: ${report.detail}`));
		return true;
	});
	for (const errorMessage of [undefined, "", "  ", { toString: () => assert.fail("Non-text error must not be serialized") }] as unknown as (string | undefined)[]) {
		const reply = message({ stopReason: "error", errorMessage, content: forbidden });
		const f = registry([{ type: "error", reason: "error", error: reply }], reply);
		await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), { message: "Dream model call failed: provider error (no error message)" });
	}
});

test("unexpected tool-call events explain rejection without reading tool names or arguments", async () => {
	const forbidden = new Proxy({ type: "toolCall" as const, id: "fixture", name: "fixture", arguments: {} }, { get: () => assert.fail("Tool payload must not be inspected"), ownKeys: () => assert.fail("Tool payload must not be serialized") });
	for (const type of ["toolcall_start", "toolcall_delta", "toolcall_end"] as const) {
		const f = registry([{ type, contentIndex: 0, partial: message({ content: [forbidden] }), toolCall: forbidden, delta: "" } as AssistantMessageEvent]);
		await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), { message: "Dream model call failed: unexpected tool call" });
	}
});

for (const [change, cause] of [
	[{ provider: "other" }, "response identity does not match the dispatched model"],
	[{ model: "other" }, "response identity does not match the dispatched model"],
	[{ content: [] }, "response contained no text"],
	[{ content: [{ type: "toolCall", id: "x", name: "write", arguments: {} }] }, "unexpected non-text response content"],
	[{ content: [{ type: "text", text: "x".repeat(262145) }] }, "response exceeded the 262144-byte text limit"],
	[{ content: [{ type: "text", text: "\ud800" }] }, "response text contains invalid Unicode"],
] as [Partial<AssistantMessage>, string][]) test(`registry explains invalid result: ${cause}`, async () => {
	const reply = message(change);
	const f = registry([{ type: "done", reason: "stop", message: reply }], reply);
	await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), { message: `Dream model call failed: ${cause}` });
});

test("missing done, mismatched done/result, post-terminal updates, partial tools and over-limit partials explain failure", async () => {
	for (const [events, cause] of [
		[[], "stream ended without a terminal response"],
		[[{ type: "done", reason: "stop", message: message({ content: [{ type: "text", text: "different" }] }) }], "terminal and final response text do not match"],
		[[{ type: "done", reason: "stop", message: message() }, { type: "start", partial: message() }], "stream continued after its terminal event"],
		[[{ type: "start", partial: message({ content: [{ type: "toolCall", id: "x", name: "x", arguments: {} }] }) }], "unexpected non-text response content"],
		[[{ type: "start", partial: message({ content: [{ type: "text", text: "x".repeat(262145) }] }) }], "response exceeded the 262144-byte text limit"],
	] as [AssistantMessageEvent[], string][]) {
		const f = registry(events);
		await assert.rejects(dream.callDreamModel(request, f.ctx, model, selection, new AbortController().signal), { message: `Dream model call failed: ${cause}` });
	}
});

test("unsupported stock route refuses ordinary streaming before dispatch", async () => {
	const ctx = { modelRegistry: { streamSimple: () => assert.fail("Ordinary streaming must not substitute for subscription dispatch") } } as unknown as ExtensionContext;
	await assert.rejects(dream.callDreamModel(request, ctx, model, selection, new AbortController().signal), { message: "Dream model call failed: the selected route cannot guarantee subscription-only dreaming on this Pi SDK; nothing was dispatched" });
});

for (const scenario of ["valid", "api-key", "not-subscription", "changed", "missing-auth", "missing-key"]) {
	test(`stock subscription provider ${scenario} uses only the captured public route`, async () => {
		let calls = 0; let lookups = 0; let authCalls = 0;
		const provider = {
			id: model.provider,
			auth: { oauth: { isSubscription: scenario !== "not-subscription" }, ...(scenario === "api-key" ? { apiKey: {} } : {}) },
			streamSimple(current: typeof model, context: Context, options: { apiKey?: string; headers?: Record<string, string>; env?: Record<string, string> }) {
				calls++; assert.equal(current.id, model.id); assert.equal(options.apiKey, "synthetic-subscription");
				assert.equal(current.baseUrl, "https://selected-model.invalid");
				assert.deepEqual(options.headers, { "x-selected-model": "synthetic-header" });
				assert.deepEqual(options.env, { SYNTHETIC_REQUEST: "selected-model" });
				assert.equal(context.messages[0].role, "system");
				return { async *[Symbol.asyncIterator]() { yield { type: "done", reason: "stop", message: message() }; }, result: async () => message() };
			},
		};
		const ctx = { modelRegistry: {
			getProvider: () => { lookups++; return scenario === "changed" && lookups > 1 ? { ...provider } : provider; },
			getRegisteredProviderConfig: () => undefined,
			getRegisteredNativeProvider: () => undefined,
			getProviderAuth: async () => assert.fail("Provider-only auth would drop selected-model headers."),
			getApiKeyAndHeaders: async (current: typeof model) => {
				authCalls++; assert.strictEqual(current, model);
				return scenario === "missing-auth" ? { ok: false, error: "Synthetic auth unavailable." } : { ok: true, apiKey: scenario === "missing-key" ? undefined : "synthetic-subscription", baseUrl: "https://selected-model.invalid", headers: { "x-selected-model": "synthetic-header" }, env: { SYNTHETIC_REQUEST: "selected-model" } };
			},
			streamSimple: () => assert.fail("Stock dispatch must not resolve credentials a second time."),
		} } as unknown as ExtensionContext;
		if (scenario === "valid") {
			assert.equal(await dream.callDreamModel(request, ctx, model, selection, new AbortController().signal), " {🌱} \n");
			assert.equal(calls, 1); assert.equal(authCalls, 1);
		} else {
			await assert.rejects(dream.callDreamModel(request, ctx, model, selection, new AbortController().signal), /nothing was dispatched/);
			assert.equal(calls, 0);
			if (scenario === "api-key" || scenario === "not-subscription") assert.equal(authCalls, 0);
		}
	});
}

test("registry cancellation rejects a stalled stream immediately and passes a client-owned signal", async () => {
	const controller = new AbortController(); let received: AbortSignal | undefined;
	const ctx = { modelRegistry: { streamSubscriptionSimple(_model: unknown, _context: unknown, options: { signal: AbortSignal }) {
		received = options.signal;
		return { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }), result: () => new Promise(() => {}) };
	} } } as unknown as ExtensionContext;
	const pending = dream.callDreamModel(request, ctx, model, selection, controller.signal);
	controller.abort();
	await assert.rejects(pending, { message: "Dream call cancelled." });
	assert.equal(received?.aborted, true);
});

for (const scenario of ["missing", "conflict", "unapproved", "eventMismatch", "resultMismatch", "same"] as const) test(`virtual selection subscription dispatch observer ${scenario}`, async () => {
	const virtualModel = { ...model, api: "pi-virtual" };
	const physical = Object.freeze({ provider: "anthropic", modelID: "physical", api: "anthropic-messages" });
	const physicalMessage = message({ provider: physical.provider, model: physical.modelID, api: physical.api });
	let calls = 0;
	const ctx = { modelRegistry: { streamSubscriptionSimple(current: unknown, context: Context, options: SubscriptionSimpleStreamOptions) {
		calls++; assert.strictEqual(current, virtualModel); assert.equal(context.systemPrompt, request.systemPrompt);
		assert.deepEqual(Object.keys(options).sort(), ["onDispatch", "reasoning", "signal"]);
		assert.ok(options.onDispatch);
		if (scenario !== "missing") {
			if (scenario === "unapproved") assert.throws(() => options.onDispatch!({ ...physical, provider: "unsupported" }));
			else assert.equal(options.onDispatch(physical), undefined);
			if (scenario === "same") assert.equal(options.onDispatch(physical), undefined);
			if (scenario === "conflict") { try { options.onDispatch({ ...physical, modelID: "changed" }); } catch {} }
		}
		const eventMessage = scenario === "eventMismatch" ? message() : physicalMessage;
		const resultMessage = scenario === "resultMismatch" ? message() : physicalMessage;
		return { async *[Symbol.asyncIterator]() { yield { type: "done", reason: "stop", message: eventMessage }; }, result: async () => resultMessage };
	} } } as unknown as ExtensionContext;
	const work = dream.callDreamModel(request, ctx, virtualModel, selection, new AbortController().signal);
	if (scenario === "same") assert.equal(await work, " {🌱} \n");
	else await assert.rejects(work, { message: `Dream model call failed: ${scenario === "conflict" || scenario === "unapproved" ? "physical dispatch changed or was invalid" : "response identity does not match the dispatched model"}` });
	assert.equal(calls, 1);
});

test("selection mismatch fails before registry; process environment excludes provider and Pi auth", async () => {
	const f = registry([]);
	await assert.rejects(dream.callDreamModel(request, f.ctx, { ...model, id: "changed" }, selection, new AbortController().signal), { message: "Dream model call failed: model selection does not match the request" });
	assert.equal(f.calls.length, 0);
	assert.deepEqual(dream.workerEnvironment({ HOME: "/home", PATH: "/bin", TMPDIR: "/tmp", LANG: "C", LC_ALL: "C", OPENAI_API_KEY: "forbidden", PI_CODING_AGENT_DIR: "forbidden", GIT_DIR: "forbidden" }), { HOME: "/home", PATH: "/bin", TMPDIR: "/tmp", LANG: "C", LC_ALL: "C" });
});

test("closed protocol rejects duplicates, invalid UTF-8, partial JSON, surrogate escapes and changed bindings", () => {
	for (const bytes of [Buffer.from('{"type":1,"type":2}'), Buffer.from([0xff]), Buffer.from('{"x":"\\ud800"}'), Buffer.from('{}x'), Buffer.from('{')]) assert.throws(() => dream.parseDreamJSON(bytes));
	assert.deepEqual(dream.parseDreamJSON(Buffer.from('{"text":"café 🌱"}')), { text: "café 🌱" });
	assert.deepEqual(dream.dreamRequest(request, start), request);
	for (const change of [{ extra: 1 }, { requestID: "wrong" }, { generation: 0 }, { generation: "18446744073709551616" }, { selection: { ...selection, modelID: "changed" } }, { invocationID: "wrong" }, { messages: [{ role: "assistant", text: "x", timestampMilliseconds: 0 }] }]) assert.throws(() => dream.dreamRequest({ ...request, ...change }, start));
	assert.deepEqual(dream.dreamReport(final, start), final);
	for (const change of [{ extra: 1 }, { status: "approved" }, { generation: 0 }, { isBacklog: 1 }, { status: "completed" }]) assert.throws(() => dream.dreamReport({ ...final, ...change }, start));
});

test("report escapes controls and bidirectional text, speaks plainly, and native Text fits narrow terminals", () => {
	const commit = "a".repeat(40);
	const report = dream.dreamReport({ ...final, status: "completed", generation: "1", runID: "run", base: "b".repeat(40), proposals: [{ ref: `refs/heads/proposals/${commit}`, commit, base: "b".repeat(40), path: "MEMORY.md", sources: [{ sessionID: "session", entryID: "entry", partIndex: 0 }], contradictions: "café 🌱\u001b[31m\u202econtrol" }], notes: [{ kind: "noChange", sources: [{ sessionID: "session", entryID: "other", partIndex: 0 }], explanation: "One-off.", reasonCode: "notDurable", ownerReference: null, contradictions: "" }] }, start);
	const output = dream.dreamReviewText(report);
	assert.ok(output.includes("\\u{1B}")); assert.ok(output.includes("\\u{202E}"));
	assert.ok(!output.includes("$'\\x")); assert.ok(!output.includes("refs/heads")); assert.ok(!output.includes("session:entry"));
	assert.ok(output.includes("1 proposal saved for review in conversation. Memory is unchanged.")); assert.ok(output.includes("1 source in 1 session")); assert.ok(output.includes("not a durable preference: 1"));
	const pending = dream.dreamReport({ ...final, status: "pending", generation: "0", runID: "run", base: "b".repeat(40), reason: "callbackFailure" }, start);
	assert.ok(dream.dreamReviewText(pending).includes("The model call failed before its reply was saved."));
	assert.ok(!output.includes("\u001b"));
	for (const width of [12, 30, 80]) {
		const lines = new tui.Text(output, 0, 0).render(width);
		assert.ok(lines.every((line) => tui.visibleWidth(line) <= width));
		assert.ok(!lines.join("").includes(commit));
	}
});

function historyFixture() {
	const renderers = new Map();
	const pi = { registerCommand: () => assert.fail("History must not register commands"), registerEntryRenderer: (name: string, renderer: unknown) => renderers.set(name, renderer) } as unknown as ExtensionAPI;
	dream.registerDreamHistory(pi);
	return { renderers };
}

test("saved coverage renders actual elapsed or unknown for older entries and rejects invalid metadata", () => {
	const f = historyFixture();
	const renderer = f.renderers.get(dream.DREAM_REVIEW_TYPE);
	const coverage = { archiveBytes: 500, processedBytes: 250, plannedBytes: 100, completedBytes: 100, undreamtBytes: 250, nextBytes: 100, repeatedRecords: 0, estimateSeconds: null };
	const render = (metadata: object) => renderer({ data: { report: final, memory: "/memory", coverage, ...metadata } }).render(200).join("\n");
	assert.match(render({ elapsedSeconds: 25.9 }), /elapsed 25s/);
	assert.match(render({}), /elapsed unknown/);
	assert.match(render({}), /Backlog unknown for this saved batch/);
	const { detail: _detail, ...saved } = final;
	assert.match(renderer({ data: { report: saved, memory: "/memory" } }).render(200).join("\n"), /^Dream: noNewRecords/);
	assert.match(renderer({ data: { report: { ...final, status: "blocked", reason: "workerFailure", detail: "dream storage limit exceeded" }, memory: "/memory" } }).render(200).join("\n"), /The worker hit an error before it finished.\nCause: dream storage limit exceeded/);
	for (const elapsedSeconds of [-1, NaN, Infinity, "25", null]) assert.match(render({ elapsedSeconds }), /Dream review unavailable/);
	assert.match(render({ coverage: { ...coverage, completedBytes: 101 } }), /Dream review unavailable/);
	assert.match(render({ coverage: { ...coverage, nextBytes: null } }), /Dream review unavailable/);
});

test("prior saved coverage preserves report and batch without inventing archive coverage or elapsed", () => {
	const renderer = historyFixture().renderers.get(dream.DREAM_REVIEW_TYPE);
	const coverage = { plannedBytes: 100, completedBytes: 100, undreamtBytes: 250, nextBytes: 100, repeatedRecords: 2, estimateSeconds: null };
	const report = { ...final, status: "completed", generation: "1", runID: "run", base: "b".repeat(40), proposals: [{ ref: `refs/heads/proposals/${"a".repeat(40)}`, commit: "a".repeat(40), base: "b".repeat(40), path: "MEMORY.md", sources: [{ sessionID: "session", entryID: "entry", partIndex: 0 }], contradictions: "" }] };
	const render = (savedCoverage: object) => renderer({ data: { report, memory: "/memory", coverage: savedCoverage } }).render(200).join("\n");
	const output = render(coverage);
	assert.match(output, /1 proposal saved/);
	assert.match(output, /Proposal for MEMORY.md/);
	assert.match(output, /elapsed unknown/);
	assert.match(output, /Backlog unknown for this saved batch/);
	assert.match(output, /This batch 0\.0 MB · next batch 0\.0 MB · estimate unknown · retry repeats 2 records/);
	for (const change of [{ extra: 1 }, { completedBytes: 101 }, { nextBytes: null }, { plannedBytes: -1 }, { repeatedRecords: 1001 }, { estimateSeconds: 0 }]) assert.match(render({ ...coverage, ...change }), /Dream review unavailable/);
	assert.throws(() => dream.dreamCoverage({ ...coverage, version: 1, type: "progress", invocationID: start.invocationID }, start));
});

test("batch text follows the model context window and small models are refused before a worker starts", () => {
	assert.deepEqual([undefined, 32_768, 65_535, 65_536, 262_144, 2_000_000].map(dream.dreamBatchTextBytes), [null, null, null, 65_536, 262_144, 1_048_576]);
});

test("warm imports and full factories register tools but no commands or review modes under 50 ms", async (t) => {
	const names: string[] = [];
	const pi = { on: () => {}, registerFlag: () => assert.fail("Memory must not register an alternate review mode"), registerCommand: () => assert.fail("Memory must not register commands"), registerEntryRenderer: () => {}, registerMessageRenderer: () => {}, registerTool: (tool: { name: string }) => names.push(tool.name) } as unknown as ExtensionAPI;
	const expected = ["memory_add", "memory_delete", "memory_get", "memory_list", "memory_queue", "memory_update"];
	coreMemories(pi);
	assert.deepEqual(names.sort(), expected);
	for (let run = 0; run < 2; run++) {
		names.length = 0;
		const before = performance.now(); await import("./index.ts"); coreMemories(pi);
		const elapsed = performance.now() - before;
		t.diagnostic(`warm import + factory ${run + 1}: ${elapsed.toFixed(3)} ms`); assert.ok(elapsed < 50);
		assert.deepEqual(names.sort(), expected);
	}
});

test("installer replacement uses the stable snippet path without rewriting saved roots", async (t) => {
	const home = await mkdtemp("/private/tmp/dream-install-roots-");
	t.after(() => rm(home, { recursive: true, force: true }));
	const agent = join(home, "agent");
	const snippets = join(agent, "extensions", "prompt-snippets", "snippets");
	await mkdir(snippets, { recursive: true });
	const roots = await dream.dreamRoots(agent, home, home);
	assert.equal(roots.snippets, snippets);
	await mkdir(roots.state, { recursive: true, mode: 0o700 });
	await chmod(roots.state, 0o700);
	const file = join(roots.state, "root.json");
	for (const layer of ["agents-runtime", "agents-resources"]) {
		const old = join(home, ".cache/tool-sync/installs/old/home/.local/lib", layer, "pi/extensions/prompt-snippets/snippets");
		const bytes = JSON.stringify({ schemaVersion: 2, sessions: roots.sessions, memory: roots.memory, stripping: [old], globalAgents: roots.globalAgents });
		await writeFile(file, bytes, { mode: 0o600 });
		assert.deepEqual(await dream.dreamRoots(agent, home, home), roots);
		assert.equal(await readFile(file, "utf8"), bytes);
	}
});

test("root configuration retains null or missing configured optional folders and refuses changed/unsafe metadata", async (t) => {
	const home = await mkdtemp("/private/tmp/dream-roots-");
	t.after(() => rm(home, { recursive: true, force: true }));
	const agent = join(home, "agent"); await mkdir(agent);
	const roots = await dream.dreamRoots(agent, home, home);
	assert.equal(roots.prompts, null);
	await mkdir(roots.state, { recursive: true, mode: 0o700 }); await chmod(roots.state, 0o700);
	const binding = { schemaVersion: 2, sessions: roots.sessions, memory: roots.memory, stripping: roots.snippets ? [roots.snippets] : [], globalAgents: roots.globalAgents };
	const rootFile = join(roots.state, "root.json");
	await writeFile(rootFile, JSON.stringify(binding), { mode: 0o600 });
	await mkdir(join(agent, "prompts"));
	assert.equal((await dream.dreamRoots(agent, home, home)).prompts, null);
	await writeFile(rootFile, JSON.stringify({ ...binding, stripping: [...binding.stripping, join(agent, "prompts")] }));
	await rm(join(agent, "prompts"), { recursive: true });
	assert.equal((await dream.dreamRoots(agent, home, home)).prompts, join(agent, "prompts"));
	await assert.rejects(dream.dreamRoots(join(home, "other-agent"), home, home));
	await writeFile(rootFile, JSON.stringify({ ...binding, originalRoots: [binding.sessions, binding.memory, ...binding.stripping] }));
	assert.deepEqual(await dream.dreamRoots(agent, home, home), roots);
	for (const bytes of ['{"schemaVersion":2,"schemaVersion":2}', JSON.stringify({ ...binding, stripping: ["/unknown"] }), "x".repeat(1_048_577)]) {
		await writeFile(rootFile, bytes); await assert.rejects(dream.dreamRoots(agent, home, home));
	}
	await writeFile(rootFile, JSON.stringify(binding)); await chmod(rootFile, 0o644);
	await assert.rejects(dream.dreamRoots(agent, home, home));
	await rm(rootFile); await symlink(join(home, "not-root"), rootFile);
	await assert.rejects(dream.dreamRoots(agent, home, home));
});

test("backlog bar fills dreamt bytes from the right and coverage refuses invented bytes", () => {
	const megabyte = 1_048_576;
	const frame = { version: 1, type: "progress", invocationID: start.invocationID, backlogBytes: 300 * megabyte, backlogLimitBytes: 400 * megabyte, plannedBytes: 4 * megabyte, completedBytes: 0, undreamtBytes: 200 * megabyte, nextBytes: 4 * megabyte, repeatedRecords: 2, estimateSeconds: null };
	const coverage = dream.dreamCoverage(frame, start);
	assert.equal(dream.dreamBacklogBar(coverage, 40), "░".repeat(16) + "▒".repeat(16) + "█".repeat(8));
	assert.equal(dream.dreamBacklogBar({ ...coverage, completedBytes: 4 * megabyte }, 504), "░".repeat(204) + "▒".repeat(196) + "█".repeat(104));
	assert.equal(dream.dreamBacklogBar({ ...coverage, undreamtBytes: 0, plannedBytes: 0, nextBytes: 0 }, 70), "░".repeat(40) + "█".repeat(30));
	const output = dream.dreamProgressText(coverage, 12, "model call", 40);
	assert.equal(output, [
		"Dream · model call · elapsed 12s",
		"░".repeat(16) + "▒".repeat(16) + "█".repeat(8),
		"░ free 200.0 MB · ▒ not dreamt 200.0 MB · █ dreamt 100.0 MB · cap 400.0 MB undreamt · last 7 days",
		"This batch 4.0 MB · next batch 4.0 MB · estimate unknown · retry repeats 2 records",
	].join("\n"));
	assert.match(dream.dreamProgressText({ ...coverage, estimateSeconds: 20 }, 12, "model call"), /estimate ~20s/);
	assert.match(dream.dreamProgressText(dream.dreamCoverage({ ...frame, backlogBytes: null, backlogLimitBytes: null, undreamtBytes: null, nextBytes: null }, start), 12, "model call"), /Backlog unknown for this saved batch/);
	for (const change of [{ archiveBytes: 350 * megabyte }, { backlogBytes: 199 * megabyte }, { undreamtBytes: null }, { backlogLimitBytes: null }, { completedBytes: 5 * megabyte }, { nextBytes: 197 * megabyte }, { estimateSeconds: -1 }]) assert.throws(() => dream.dreamCoverage({ ...frame, ...change }, start));
	for (const width of [20, 40, 80]) {
		const renderer = historyFixture().renderers.get(dream.DREAM_REVIEW_TYPE);
		const lines = renderer({ data: { report: final, memory: "/memory", coverage } }).render(width);
		assert.ok(lines.every((line: string) => tui.visibleWidth(line) <= width));
		assert.ok(lines.includes("░".repeat(width * 2 / 5) + "▒".repeat(width * 2 / 5) + "█".repeat(width / 5)));
	}
});
