import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { setImmediate, setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { DreamReport, DreamRequest, runDreamWorker } from "./dream.ts";
import type { openQueueClient, QueueConnection, QueueObject } from "./queue-client.ts";
import "./test/host.ts";
const { memoryRequestIdentity, reviewQueuedMemory, registerQueuedRuntime, assertArchivedRequest } = await import("./queued-runtime.ts");
const sha = (value: string): string => createHash("sha256").update(value).digest("hex");
function context() {
	const entries = [{ type: "message", id: "user-entry", message: { role: "user" } }];
	const ctx = { mode: "tui", hasUI: true, cwd: "/synthetic", model: { provider: "openai-codex", id: "selected", contextWindow: 262_144 }, thinkingLevel: "high", isIdle: () => true, hasPendingMessages: () => false, sessionManager: { getSessionId: () => "session", getBranch: () => entries } } as unknown as ExtensionContext;
	const toolContext: ExtensionToolContext = { ...ctx, tools: [], executeTool: async () => { assert.fail("Unexpected nested fixture tool call."); } };
	return { ctx: toolContext, entries };
}
function frame(identity: { sessionID: string; requestID: string }, isDetachRequired = false) {
	const payload = { claimID: "private", sequence: "1", request: identity, finding: { revision: "a".repeat(64), candidateID: "b".repeat(64), proposed: Buffer.from("  exact finding\n").toString("base64"), reason: "exact reason" }, before: "", after: Buffer.from("  exact finding\n").toString("base64"), replacement: Buffer.from("# Memory\n\n  exact finding\n").toString("base64"), previewDigest: "c".repeat(64), currentBase: "d".repeat(40), isDetachRequired };
	const encoded = JSON.stringify(payload);
	return { type: "presentation", display: { presentation: payload, displayDigest: sha(encoded) }, displayBytes: Buffer.from(encoded).toString("base64") };
}
type Question = { requestId: string; onPresented: () => Promise<void>; params: { question: string; details: string } };
function bus(choose: (question: Question) => Promise<string> = async () => "approve") {
	const listeners = new Map<string, (value: unknown) => void>();
	const emit = (name: string, value: unknown) => {
		listeners.get(name)?.(value);
		const request = value as { requestId: string };
		if (name === "ask-user-question:rpc:ping") emit(`${name}:reply:${request.requestId}`, { success: true, data: { version: 1 } });
		if (name === "ask-user-question:rpc:ask") {
			const question = value as Question;
			void question.onPresented().then(async () => {
				const choice = await choose(question);
				emit(`${name}:reply:${question.requestId}`, { success: true, data: { details: { status: "answered", provenance: "interactive-user", question: question.params.question, context: question.params.details, mode: "single-select", answers: [{ type: "option", value: choice }] } } });
			}).catch(() => {});
		}
	};
	return { events: { emit, on: (name: string, handler: (value: unknown) => void) => { listeners.set(name, handler); return () => { listeners.delete(name); }; } }, appendEntry: () => {} } as unknown as ExtensionAPI;
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

test("queue choice follows exact display acknowledgement and never exposes private claim", async () => {
	const { ctx } = context();
	const identity = memoryRequestIdentity(ctx);
	const display = frame(identity);
	const calls: string[] = [];
	let acknowledge!: () => void;
	const gate = new Promise<void>((resolve) => { acknowledge = resolve; });
	const client: QueueConnection = { close: async () => {}, request: async (type, fields, isPrivate) => {
		calls.push(type);
		if (type === "claim") return display;
		if (type === "presented") { assert.equal(isPrivate, true); await gate; return { type, displayDigest: display.display.displayDigest }; }
		if (type === "choice") { assert.equal(isPrivate, true); return { type: "decision", receipt: { decisionID: fields!.decisionID, displayDigest: display.display.displayDigest, status: "approved", commit: "e".repeat(40), auditRef: "refs/notes/synthetic" } }; }
		return { type: "released" };
	} };
	const pending = reviewQueuedMemory(bus(), ctx, client, identity, "claim", { revision: "a".repeat(64) }, new AbortController().signal, () => true);
	await setImmediate();
	assert.deepEqual(calls, ["claim", "presented"]);
	acknowledge();
	const result = await pending;
	assert.equal(result.status, "approved");
	assert.deepEqual(calls, ["claim", "presented", "choice", "release"]);
	assert.ok(!JSON.stringify(result).includes("private"));
});

test("cancelled and stale callbacks release native ownership without choice", async () => {
	for (const isStale of [false, true]) {
		const { ctx } = context();
		const identity = memoryRequestIdentity(ctx);
		const display = frame(identity);
		const controller = new AbortController();
		let isCurrent = true;
		const calls: string[] = [];
		const client: QueueConnection = { close: async () => {}, request: async (type) => {
			calls.push(type);
			if (type === "claim") return display;
			if (type === "presented") { if (isStale) isCurrent = false; else controller.abort(); return { type, displayDigest: display.display.displayDigest }; }
			assert.notEqual(type, "choice");
			return { type: "released" };
		} };
		await reviewQueuedMemory(bus(), ctx, client, identity, "claim", {}, controller.signal, () => isCurrent).catch((error) => assert.match(String(error), /acknowledgement failed/));
		assert.ok(calls.includes("release"));
		assert.ok(!calls.includes("choice"));
	}
});

test("detach is a separate choice followed by a fresh exact preview and fresh approval", async () => {
	const { ctx } = context(); const identity = memoryRequestIdentity(ctx);
	const actions: unknown[] = []; let claims = 0; let display = frame(identity, true);
	const client: QueueConnection = { close: async () => {}, request: async (type, fields) => {
		if (type === "claim") { display = frame(identity, claims++ === 0); return display; }
		if (type === "presented") return { type, displayDigest: display.display.displayDigest };
		if (type === "choice") { actions.push(fields!.action); return { type: "decision", receipt: { decisionID: fields!.decisionID, displayDigest: display.display.displayDigest, status: fields!.action === "detach" ? "detached" : "approved", commit: "e".repeat(40), auditRef: "refs/notes/synthetic" } }; }
		return { type: "released" };
	} };
	const pi = bus(async (question) => question.params.question.startsWith("Detach") ? "detach" : "approve");
	assert.equal((await reviewQueuedMemory(pi, ctx, client, identity, "claim", {}, new AbortController().signal, () => true)).status, "approved");
	assert.equal(claims, 2); assert.deepEqual(actions, ["detach", "approve"]);
});

test("active transcript evidence fails closed before archived model dispatch", () => {
	const request = { messages: [{ role: "user", text: JSON.stringify({ primaryEvidence: [{ source: { session: "session", entry: "entry", part: 0 } }] }) }] } as DreamRequest;
	assert.throws(() => assertArchivedRequest(request, "session"), /active session/);
	assert.doesNotThrow(() => assertArchivedRequest(request, "another-session"));
});

function runtime(run: typeof runDreamWorker, mode = "tui", openFailure?: Error) {
	const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
	const flags = new Map<string, boolean | string>();
	const flagRegistrations = new Map<string, unknown>();
	const flagReads: string[] = [];
	const opened: Parameters<typeof openQueueClient>[] = [];
	const memberships: string[] = [];
	const closed: string[] = [];
	let registeredTool: ToolDefinition | undefined;
	const pi = { ...bus(), on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => { handlers.set(name, handler); },
		registerFlag: (name: string, options: unknown) => { flagRegistrations.set(name, options); },
		getFlag: (name: string) => { flagReads.push(name); return flags.get(name); },
		registerTool: (tool: ToolDefinition) => { registeredTool = tool; }, getThinkingLevel: () => "high" } as unknown as ExtensionAPI;
	const { ctx } = context(); (ctx as { mode: string }).mode = mode;
	let changed = () => {}; let isPeerForeground = false;
	const stop = registerQueuedRuntime(pi, { run, idleMilliseconds: 5,
		open: async (...args) => { opened.push(args); if (openFailure) throw openFailure; return { request: async () => ({ type: "queue", rows: [], nextOffset: null }), close: async () => { closed.push("closed"); } }; },
		membership: async (directory, _initial, onChanged) => { memberships.push(directory); changed = onChanged; return { set: () => {}, snapshot: async () => ({ sessionIDs: ["session", "another-live-session"].sort(), isForeground: isPeerForeground }), close: async () => {} }; }, roots: async () => ({ state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }), scope: async () => ({}) });
	return { ctx, stop, flags, flagRegistrations, flagReads, opened, memberships, closed,
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

test("helper death cancels an unanswered question and releases the native claim", async () => {
	const { ctx } = context(); const identity = memoryRequestIdentity(ctx); const display = frame(identity);
	const lifetime = new AbortController(); const calls: string[] = [];
	const client: QueueConnection = { signal: lifetime.signal, close: async () => {}, request: async (type) => {
		calls.push(type);
		if (type === "claim") return display;
		if (type === "presented") return { type, displayDigest: display.display.displayDigest };
		assert.notEqual(type, "choice");
		return { type: "released" };
	} };
	const pi = bus(async () => new Promise<string>(() => {}));
	const pending = reviewQueuedMemory(pi, ctx, client, identity, "claim", {}, new AbortController().signal, () => true);
	await setImmediate(); lifetime.abort();
	assert.equal((await pending).status, "cancelled");
	assert.deepEqual(calls, ["claim", "presented", "release"]);
});

test("review profile survives late flag binding and session restart without genuine background work", async () => {
	let runs = 0;
	const f = runtime(async () => { runs++; return { status: "pending" } as DreamReport; });
	try {
		assert.deepEqual(f.flagReads, []);
		f.flags.set("memory-queue-review-config", "/synthetic/review-config.json");
		await f.emit("session_start");
		await f.tool.execute("first", { operation: "pending" }, undefined, undefined, f.ctx);
		assert.equal(f.opened[0]?.[2], "/synthetic/review-config.json");
		assert.deepEqual(f.flagRegistrations.get("memory-queue-review-config"), { type: "string", description: "Review one memory configuration without background intake." });
		f.flags.set("memory-queue-review-config", "/synthetic/changed-config.json");
		await f.emit("session_start");
		await f.tool.execute("second", { operation: "pending" }, undefined, undefined, f.ctx);
		assert.deepEqual(f.opened.map((args) => args[2]), ["/synthetic/review-config.json", "/synthetic/review-config.json"]);
		assert.equal(f.flagReads.length, 1);
		for (const event of ["agent_end", "model_select", "thinking_level_select", "session_tree", "session_compact", "session_compact_failed"]) await f.emit(event);
		await sleep(20);
		assert.equal(f.memberships.length, 0); assert.equal(runs, 0); assert.equal(f.closed.length, 2);
	} finally { await f.stop(); }
});

test("invalid explicit review profiles cannot open default data or join background membership", async () => {
	for (const value of ["", "relative.json", true]) {
		let runs = 0;
		const f = runtime(async () => { runs++; return { status: "pending" } as DreamReport; });
		try {
			f.flags.set("memory-queue-review-config", value);
			await assert.rejects(f.emit("session_start"), /absolute configuration filename/);
			await assert.rejects(f.tool.execute("invalid", { operation: "pending" }, undefined, undefined, f.ctx), /absolute configuration filename/);
			await f.emit("agent_end"); await sleep(20);
			assert.equal(f.opened.length, 0); assert.equal(f.memberships.length, 0); assert.equal(runs, 0);
		} finally { await f.stop(); }
	}
});

test("an explicit review profile refusal never retries with default data", async () => {
	const f = runtime(async () => ({ status: "pending" }) as DreamReport, "tui", new Error("Fixture review profile unavailable."));
	try {
		f.flags.set("memory-queue-review-config", "/synthetic/missing-config.json");
		await f.emit("session_start");
		await assert.rejects(f.tool.execute("refused", { operation: "pending" }, undefined, undefined, f.ctx), /Fixture review profile unavailable/);
		assert.equal(f.opened.length, 1); assert.equal(f.opened[0]?.[2], "/synthetic/missing-config.json");
		assert.equal(f.closed.length, 0); assert.equal(f.memberships.length, 0);
	} finally { await f.stop(); }
});

test("absent review profile keeps default foreground opening and interactive membership", async () => {
	const f = runtime(async () => ({ status: "pending" }) as DreamReport);
	try {
		await f.emit("session_start");
		await f.tool.execute("default", { operation: "pending" }, undefined, undefined, f.ctx);
		assert.equal(f.opened.length, 1); assert.equal(f.opened[0]?.length, 2);
		assert.equal(f.memberships.length, 1); assert.equal(f.closed.length, 1);
	} finally { await f.stop(); }
});
