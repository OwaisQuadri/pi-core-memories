import assert from "node:assert/strict";
import { setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { DreamReport, DreamRequest, runDreamWorker } from "./dream.ts";
import type { openQueueClient } from "./queue-client.ts";
import "./test/host.ts";
const { memoryRequestIdentity, registerQueuedRuntime, assertArchivedRequest } = await import("./queued-runtime.ts");
function context() {
	const entries = [{ type: "message", id: "user-entry", message: { role: "user" } }];
	const ctx = { mode: "tui", hasUI: true, cwd: "/synthetic", model: { provider: "openai-codex", id: "selected", contextWindow: 262_144 }, thinkingLevel: "high", isIdle: () => true, hasPendingMessages: () => false, sessionManager: { getSessionId: () => "session", getBranch: () => entries } } as unknown as ExtensionContext;
	const toolContext: ExtensionToolContext = { ...ctx, tools: [], executeTool: async () => { assert.fail("Unexpected nested fixture tool call."); } };
	return { ctx: toolContext, entries };
}
test("same durable request survives tool leaves, compaction and runtime restart", () => {
	const f = context();
	const first = memoryRequestIdentity(f.ctx);
	f.entries.push({ type: "message", id: "tool-leaf", message: { role: "toolResult" } });
	assert.deepEqual(memoryRequestIdentity(f.ctx), first);
	const restarted = { ...f.ctx, sessionManager: { ...f.ctx.sessionManager, getBranch: () => [...f.entries, { type: "compaction", id: "compact" }] } } as unknown as ExtensionContext;
	assert.deepEqual(memoryRequestIdentity(restarted), first);
	f.entries.push({ type: "message", id: "next-user", message: { role: "user" } });
	assert.notDeepEqual(memoryRequestIdentity(f.ctx), first);
});

test("active transcript evidence fails closed before archived model dispatch", () => {
	const request = { messages: [{ role: "user", text: JSON.stringify({ primaryEvidence: [{ source: { session: "session", entry: "entry", part: 0 } }] }) }] } as DreamRequest;
	assert.throws(() => assertArchivedRequest(request, "session"), /active session/);
	assert.doesNotThrow(() => assertArchivedRequest(request, "another-session"));
});

function runtime(run: typeof runDreamWorker, mode = "tui", openFailure?: Error) {
	const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
	const opened: Parameters<typeof openQueueClient>[] = [];
	const memberships: string[] = [];
	const closed: string[] = [];
	let registeredTool: ToolDefinition | undefined;
	const pi = { events: { emit: () => assert.fail("Memory must not open a review dialog.") }, on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => { handlers.set(name, handler); },
		registerFlag: () => assert.fail("Memory must not register a review mode"),
		getFlag: () => assert.fail("Memory must not select a separate review mode"),
		registerTool: (tool: ToolDefinition) => { registeredTool = tool; }, getThinkingLevel: () => "high" } as unknown as ExtensionAPI;
	const { ctx } = context(); (ctx as { mode: string }).mode = mode;
	let changed = () => {}; let isPeerForeground = false;
	const stop = registerQueuedRuntime(pi, { run, idleMilliseconds: 5,
		open: async (...args) => { opened.push(args); if (openFailure) throw openFailure; return { request: async () => ({ type: "queue", rows: [], nextOffset: null }), close: async () => { closed.push("closed"); } }; },
		membership: async (directory, _initial, onChanged) => { memberships.push(directory); changed = onChanged; return { set: () => {}, snapshot: async () => ({ sessionIDs: ["session", "another-live-session"].sort(), isForeground: isPeerForeground }), close: async () => {} }; }, roots: async () => ({ state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }), scope: async () => ({}) });
	return { ctx, stop, opened, memberships, closed,
		get tool() { assert.ok(registeredTool); return registeredTool; },
		peerForeground: () => { isPeerForeground = true; changed(); }, emit: async (name: string) => handlers.get(name)?.({}, ctx) };
}

test("foreground work cancels idle background and shutdown stops rescheduling", async () => {
	let enter!: () => void; const entered = new Promise<void>((resolve) => { enter = resolve; });
	let workerSignal: AbortSignal | undefined; let runs = 0;
	const f = runtime(async (_start, _call, signal, _progress, protect) => {
		runs++; workerSignal = signal; assert.equal(typeof protect, "function");
		assert.deepEqual((_start as typeof _start & { excludedSessionIDs: string[] }).excludedSessionIDs, ["another-live-session", "session"]); enter();
		await new Promise<void>((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
		throw new Error("cancelled");
	});
	await f.emit("session_start"); await Promise.race([entered, sleep(1000).then(() => assert.fail("No idle worker"))]);
	await f.emit("before_agent_start"); assert.equal(workerSignal!.aborted, true);
	await f.stop(); await sleep(20); assert.equal(runs, 1);
});

test("a peer foreground notification aborts an already running local worker", async () => {
	let enter!: () => void; const entered = new Promise<void>((resolve) => { enter = resolve; });
	let workerSignal: AbortSignal | undefined;
	const f = runtime(async (_start, _call, signal) => { workerSignal = signal; enter(); await new Promise<void>((resolve) => signal.addEventListener("abort", () => resolve(), { once: true })); throw new Error("cancelled"); });
	await f.emit("session_start"); await Promise.race([entered, sleep(1000).then(() => assert.fail("No idle worker"))]);
	f.peerForeground(); assert.equal(workerSignal!.aborted, true); await f.stop();
});

test("noninteractive hosts never start background and busy retries are bounded", async () => {
	const rpc = runtime(async () => assert.fail("RPC must not schedule"), "rpc");
	await rpc.emit("session_start"); await sleep(20); await rpc.stop();
	let runs = 0;
	const f = runtime(async () => { runs++; return { status: "busy" } as DreamReport; });
	await f.emit("session_start"); await sleep(120); await f.stop(); assert.equal(runs, 3);
});

test("a native queue refusal never retries another context", async () => {
	const f = runtime(async () => ({ status: "pending" }) as DreamReport, "tui", new Error("Native queue unavailable."));
	try {
		await f.emit("session_start");
		await assert.rejects(f.tool.execute("refused", { operation: "pending" }, undefined, undefined, f.ctx), /Native queue unavailable/);
		assert.equal(f.opened.length, 1); assert.equal(f.opened[0]?.length, 2);
		assert.equal(f.closed.length, 0); assert.equal(f.memberships.length, 1);
	} finally { await f.stop(); }
});

test("ordinary conversation keeps the shared queue and interactive background membership", async () => {
	const f = runtime(async () => ({ status: "pending" }) as DreamReport);
	try {
		await f.emit("session_start");
		assert.doesNotMatch(JSON.stringify(f.tool.parameters), /"review"|"manage"|"confirm-reviewed"/);
		await f.tool.execute("default", { operation: "pending" }, undefined, undefined, f.ctx);
		assert.equal(f.opened.length, 1); assert.equal(f.opened[0]?.length, 2);
		assert.equal(f.memberships.length, 1); assert.equal(f.closed.length, 1);
	} finally { await f.stop(); }
});
