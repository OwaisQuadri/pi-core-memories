import assert from "node:assert/strict";
import { test } from "node:test";
import type { AssistantMessage, Context } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { DreamRequest, DreamSelection, DreamStart } from "./dream.ts";

import { tuiURL } from "./test/host.ts";
const dream = await import("./dream.ts");
const tui = await import(tuiURL) as typeof import("@earendil-works/pi-tui");
const selection: DreamSelection = { provider: "openai", modelID: "selected", thinkingLevel: "off" };
const start: DreamStart = { version: 1, type: "start", invocationID: "invocation", roots: { state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }, selection, resume: "inspectOrContinue", batchTextBytes: 262_144 };
const request: DreamRequest = { version: 1, type: "modelRequest", invocationID: "invocation", requestID: "run:" + "a".repeat(64), runID: "run", generation: "0", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection, systemPrompt: "EXACT pinned system 🌱", messages: [{ role: "user", text: "saved exact\ninput café", timestampMilliseconds: 0 }] };
const final = { version: 1, type: "final", invocationID: "invocation", status: "noNewRecords", generation: "0", runID: null, base: null, proposals: [], notes: [], isBacklog: false, isRecovered: false, reason: null, detail: null, unfinishedTails: 0 };
const model = { provider: "openai", id: "selected", api: "openai-responses" } as NonNullable<ExtensionContext["model"]>;
function message(change: Partial<AssistantMessage> = {}): AssistantMessage {
	return { role: "assistant", provider: selection.provider, model: selection.modelID, api: "openai-responses", content: [{ type: "text", text: " {" }, { type: "thinking", thinking: "not decision JSON" }, { type: "text", text: "🌱} \n" }], stopReason: "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, ...change };
}
const subscription = { isUsingOAuth: () => true, getProvider: () => ({ auth: { oauth: { isSubscription: true } } }) };
function registry(result = message()) {
	const calls: { model: unknown; context: Context; options: unknown }[] = [];
	const ctx = { modelRegistry: { ...subscription, streamSimple(current: typeof model, context: Context, options: unknown) {
		calls.push({ model: current, context, options });
		return { result: async () => result };
	} } } as unknown as ExtensionContext;
	return { ctx, calls };
}

test("registry streamSimple receives only pinned bytes and timestamps, captured model, and transport-only off mapping", async () => {
	for (const level of ["off", "medium"]) {
		const captured = { ...selection, thinkingLevel: level };
		const f = registry();
		const signal = new AbortController().signal;
		assert.equal(await dream.callDreamModel({ ...request, selection: captured }, f.ctx, model, captured, signal), " {🌱} \n");
		assert.equal(f.calls.length, 1); assert.strictEqual(f.calls[0].model, model);
		assert.deepEqual(f.calls[0].context, { systemPrompt: request.systemPrompt, messages: [{ role: "user", content: request.messages[0].text, timestamp: 0 }] });
		assert.deepEqual(Object.keys(f.calls[0].options as object).sort(), ["reasoning", "signal"]);
		assert.strictEqual((f.calls[0].options as { signal?: AbortSignal }).signal, signal);
		assert.equal((f.calls[0].options as { reasoning?: string }).reasoning, level === "off" ? undefined : level);
		assert.equal(request.selection.thinkingLevel, "off");
	}
});

test("only a subscription sign-in reaches streamSimple, so dreaming never bills an API key", async () => {
	for (const [current, change] of [
		[model, { isUsingOAuth: () => false }],
		[model, { getProvider: () => ({ auth: { oauth: { isSubscription: false } } }) }],
		[{ ...model, api: "pi-virtual" }, {}],
	] as [typeof model, object][]) {
		const ctx = { modelRegistry: { ...subscription, ...change, streamSimple: () => assert.fail("A non-subscription route must not be dispatched") } } as unknown as ExtensionContext;
		await assert.rejects(dream.callDreamModel(request, ctx, current, selection, new AbortController().signal), { message: "Dream model call failed: the selected model is not using a subscription sign-in; nothing was dispatched" });
	}
});

test("process environment excludes provider and Pi auth", () => {
	assert.deepEqual(dream.workerEnvironment({ HOME: "/home", PATH: "/bin", TMPDIR: "/tmp", LANG: "C", LC_ALL: "C", OPENAI_API_KEY: "forbidden", PI_CODING_AGENT_DIR: "forbidden", GIT_DIR: "forbidden" }), { HOME: "/home", PATH: "/bin", TMPDIR: "/tmp", LANG: "C", LC_ALL: "C" });
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

