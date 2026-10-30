import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { DreamReport, DreamRequest, DreamStart, runDreamWorker } from "./dream.ts";
import type { openQueueClient } from "./queue-client.ts";
import "./test/host.ts";
const { memoryRequestIdentity, registerQueuedRuntime, assertArchivedRequest } = await import("./queued-runtime.ts");
type TestEntry = Partial<Parameters<ExtensionAPI["sendMessage"]>[0]> & { type: string; id: string; message: { role: string; content?: string; timestamp?: number } };
function context() {
	const entries: TestEntry[] = [{ type: "message", id: "user-entry", message: { role: "user", content: "Start the conversation.", timestamp: 0 } }];
	const statuses = new Map<string, string>();
	const ui = { setStatus(key: string, value: string | undefined) { if (value === undefined) statuses.delete(key); else statuses.set(key, value); } };
	const ctx = { ui, mode: "tui", hasUI: true, cwd: "/synthetic", model: { provider: "openai-codex", id: "selected", contextWindow: 262_144 }, thinkingLevel: "high", isIdle: () => true, hasPendingMessages: () => false, sessionManager: { getSessionId: () => "session", getBranch: () => entries } } as unknown as ExtensionContext;
	const toolContext: ExtensionToolContext = { ...ctx, tools: [], executeTool: async () => { assert.fail("Unexpected nested fixture tool call."); } };
	return { ctx: toolContext, entries, statuses };
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

function runtime(run: typeof runDreamWorker, mode = "tui", openFailure?: Error, overrides: NonNullable<Parameters<typeof registerQueuedRuntime>[1]> = {}) {
	const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
	const opened: Parameters<typeof openQueueClient>[] = [];
	const marks: string[] = [];
	const unmarks: string[] = [];
	const closed: string[] = [];
	const tools = new Map<string, ToolDefinition>();
	let registeredTool: ToolDefinition | undefined;
	const messages: Parameters<ExtensionAPI["sendMessage"]>[0][] = [];
	const pending: Parameters<ExtensionAPI["sendMessage"]>[0][] = [];
	let isDeliveryDeferred = false;
	const append = (message: Parameters<ExtensionAPI["sendMessage"]>[0]) => entries.push({ ...message, type: "custom_message", id: "proposal-" + entries.length, message: { role: "custom" } });
	const pi = { events: { emit: () => assert.fail("Memory must not open a review dialog.") }, on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => { handlers.set(name, handler); },
		registerMessageRenderer: () => {},
		sendMessage: (message: Parameters<ExtensionAPI["sendMessage"]>[0]) => { messages.push(message); if (isDeliveryDeferred) pending.push(message); else append(message); },
		registerFlag: () => assert.fail("Memory must not register a review mode"),
		getFlag: () => assert.fail("Memory must not select a separate review mode"),
		registerTool: (tool: ToolDefinition) => { registeredTool = tool; tools.set(tool.name, tool); }, getThinkingLevel: () => "high" } as unknown as ExtensionAPI;
	const { ctx, entries, statuses } = context(); (ctx as { mode: string }).mode = mode;
	const peers = ["another-live-session"];
	const stop = registerQueuedRuntime(pi, { run, idleMilliseconds: 5,
		open: async (...args) => { opened.push(args); if (openFailure) throw openFailure; return { request: async () => ({ type: "queue", rows: [], nextOffset: null }), close: async () => { closed.push("closed"); } }; },
		mark: async (_directory, sessionID) => { marks.push(sessionID); return { close: async () => { unmarks.push(sessionID); } }; },
		live: async () => [...peers],
		roots: async () => ({ state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }), scope: async () => ({}), ...overrides });
	return { ctx, entries, stop, opened, marks, unmarks, peers, closed, tools, messages, statuses,
		deferDelivery: () => { isDeliveryDeferred = true; },
		deliver: () => { isDeliveryDeferred = false; for (const message of pending.splice(0)) append(message); },
		get tool() { assert.ok(registeredTool); return registeredTool; },
		emit: async (name: string, event: unknown = {}) => handlers.get(name)?.(event, ctx) };
}
const archivedRequest = (start: DreamStart, session = "archived"): DreamRequest => ({ version: 1, type: "modelRequest", invocationID: start.invocationID, requestID: "request", runID: "run", generation: "1", inputHash: "a".repeat(64), contextHash: "b".repeat(64), requestHash: "c".repeat(64), selection: start.selection, systemPrompt: "Synthetic status test", messages: [{ role: "user", text: JSON.stringify({ primaryEvidence: [{ source: { session, entry: "entry", part: 0 } }] }), timestampMilliseconds: 0 }] });

test("dreaming keeps running while this window works and reports blocked outcomes without details", async () => {
	let enter!: () => void; const entered = new Promise<void>((resolve) => { enter = resolve; });
	let release!: () => void; const released = new Promise<void>((resolve) => { release = resolve; });
	let runs = 0; let workerSignal: AbortSignal | undefined;
	const f = runtime(async (start, call, signal) => {
		runs++; workerSignal = signal;
		if (runs > 1) return { status: "blocked", reason: "PRIVATE_REASON", detail: "PRIVATE_DETAIL" } as DreamReport;
		await call(archivedRequest(start), signal);
		return { status: "noNewRecords" } as DreamReport;
	}, "tui", undefined, { call: async () => {
		assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: active");
		enter(); await released;
		return "{}";
	} });
	try {
		await f.emit("session_start");
		assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: idle");
		await Promise.race([entered, sleep(1000).then(() => assert.fail("No status dispatch"))]);
		await f.emit("input", { source: "interactive", text: "keep working" }); await f.emit("before_agent_start"); await f.emit("tool_execution_start");
		assert.equal(workerSignal!.aborted, false);
		assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: active");
		release(); await sleep(30);
		assert.equal(runs, 2);
		assert.match(f.statuses.get("pi-core-memories:dream")!, /error\(code: blocked/);
		assert.doesNotMatch(f.statuses.get("pi-core-memories:dream")!, /PRIVATE/);
	} finally { await f.stop(); }
	assert.equal(f.statuses.has("pi-core-memories:dream"), false);
});

test("a window that loses the native dream lock stays idle and keeps retrying", async () => {
	let runs = 0;
	const f = runtime(async () => { runs++; return { status: "busy" } as DreamReport; });
	try {
		await f.emit("session_start"); await sleep(120);
		assert.ok(runs > 3);
		assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: idle");
	} finally { await f.stop(); }
});

for (const boundary of ["worker", "provider", "window", "marker"] as const) {
	test(`dream status reports ${boundary} failures without raw error text`, async () => {
		const f = runtime(async () => { throw new Error("PRIVATE_MODEL_PAYLOAD"); }, "tui", undefined,
			boundary === "marker" ? { mark: async () => { throw new Error("PRIVATE_SOURCE_PATH"); } } : {});
		if (boundary === "provider") Object.assign(f.ctx, { model: { ...f.ctx.model!, provider: "unsupported" } });
		if (boundary === "window") Object.assign(f.ctx, { model: { ...f.ctx.model!, contextWindow: 1 } });
		try {
			await f.emit("session_start"); await sleep(30);
			const expected = { worker: "workerFailure", provider: "unsupportedProvider", window: "contextWindow", marker: "liveSessionUnavailable" }[boundary];
			assert.ok(f.statuses.get("pi-core-memories:dream")?.includes(`error(code: ${expected},`));
			assert.doesNotMatch(f.statuses.get("pi-core-memories:dream")!, /PRIVATE/);
		} finally { await f.stop(); }
	});
}

test("a session switch removes the old live marker before marking the replacement", async () => {
	const f = runtime(async () => assert.fail("No status test may dispatch"), "tui", undefined, { idleMilliseconds: 60_000 });
	try {
		await f.emit("session_start"); await f.emit("session_before_switch");
		assert.deepEqual(f.unmarks, ["session"]);
		await f.emit("session_start");
		assert.deepEqual(f.marks, ["session", "session"]);
		assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: idle");
	} finally { await f.stop(); }
	assert.deepEqual(f.unmarks, ["session", "session"]);
});

test("dream status reports backend failure without exposing the model error", async () => {
	const f = runtime(async (start, call, signal) => {
		await call(archivedRequest(start), signal);
		return { status: "noNewRecords" } as DreamReport;
	}, "tui", undefined, { call: async () => { throw new Error("PRIVATE_RESPONSE_TOKEN"); } });
	try {
		await f.emit("session_start"); await sleep(30);
		assert.match(f.statuses.get("pi-core-memories:dream")!, /error\(code: backendFailure,/);
		assert.doesNotMatch(f.statuses.get("pi-core-memories:dream")!, /PRIVATE/);
	} finally { await f.stop(); }
});

test("live sessions are excluded at start and a session that opens mid-run blocks its evidence", async () => {
	let excluded: string[] = []; let calls = 0;
	const f = runtime(async (start, call, signal) => {
		if (excluded.length === 0) excluded = (start as typeof start & { excludedSessionIDs: string[] }).excludedSessionIDs;
		if (!f.peers.includes("opened-later")) f.peers.push("opened-later");
		await call(archivedRequest(start, "opened-later"), signal);
		return { status: "noNewRecords" } as DreamReport;
	}, "tui", undefined, { call: async () => { calls++; return "{}"; } });
	try {
		await f.emit("session_start"); await sleep(30);
		assert.deepEqual(excluded.slice(0, 2), ["another-live-session", "session"]);
		assert.equal(calls, 0);
		assert.match(f.statuses.get("pi-core-memories:dream")!, /error\(code: workerFailure,/);
	} finally { await f.stop(); }
});

test("model selection changes cancel a running worker and shutdown stops rescheduling", async () => {
	let enter!: () => void; const entered = new Promise<void>((resolve) => { enter = resolve; });
	let workerSignal: AbortSignal | undefined; let runs = 0;
	const f = runtime(async (_start, _call, signal, _progress, protect) => {
		runs++; workerSignal = signal; assert.equal(typeof protect, "function"); enter();
		await new Promise<void>((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
		throw new Error("cancelled");
	});
	await f.emit("session_start"); await Promise.race([entered, sleep(1000).then(() => assert.fail("No worker"))]);
	await f.emit("model_select"); assert.equal(workerSignal!.aborted, true);
	await f.stop(); const after = runs; await sleep(20); assert.equal(runs, after);
});

test("noninteractive hosts never start background or mark a live session", async () => {
	const rpc = runtime(async () => assert.fail("RPC must not schedule"), "rpc");
	await rpc.emit("session_start"); await sleep(20); await rpc.stop();
	assert.deepEqual(rpc.marks, []);
});

test("a native queue refusal never retries another context", async () => {
	const f = runtime(async () => ({ status: "pending" }) as DreamReport, "tui", new Error("Native queue unavailable."));
	try {
		await f.emit("session_start");
		await assert.rejects(f.tool.execute("refused", { operation: "pending" }, undefined, undefined, f.ctx), /Native queue unavailable/);
		assert.equal(f.opened.length, 1); assert.equal(f.opened[0]?.length, 2);
		assert.equal(f.closed.length, 0); assert.equal(f.marks.length, 1);
	} finally { await f.stop(); }
});

test("ordinary conversation keeps the shared queue and the live session marker", async () => {
	const f = runtime(async () => ({ status: "pending" }) as DreamReport);
	try {
		await f.emit("session_start");
		assert.doesNotMatch(JSON.stringify(f.tool.parameters), /"review"|"manage"/);
		assert.deepEqual([...f.tools.keys()].sort(), ["memory_add", "memory_delete", "memory_get", "memory_list", "memory_queue", "memory_update"]);
		await f.tool.execute("default", { operation: "pending" }, undefined, undefined, f.ctx);
		assert.equal(f.opened.length, 1); assert.equal(f.opened[0]?.length, 2);
		assert.equal(f.marks.length, 1); assert.equal(f.closed.length, 1);
	} finally { await f.stop(); }
});

function conversationalRuntime(responses: ("approved" | "clarify" | "invalid")[] = []) {
	let f: ReturnType<typeof runtime>;
	const frames: { type: string; fields: Record<string, unknown>; isPrivate?: boolean }[] = [];
	const signals: AbortSignal[] = []; const closes: number[] = [];
	f = runtime(async () => assert.fail("A native conversation must prevent background dispatch"), "tui", undefined, {
		idleMilliseconds: 60_000,
		open: async (directory, signal) => {
			assert.ok(signal); signals.push(signal); f.opened.push([directory, signal]);
			let isManagement = false; let isRelocation = false; let digest = ""; let native: Record<string, unknown> | undefined; const clientIndex = signals.length;
			return {
				signal,
				request: async (type, fields = {}, isPrivate) => {
					frames.push({ type, fields, isPrivate });
					if (type === "claim" || type === "manage-preview" || type === "relocation-preview") {
						isManagement = type === "manage-preview";
						isRelocation = type === "relocation-preview";
						const request = fields.request as Record<string, unknown> | undefined;
						const payload = {
							claimID: "unit-claim", sequence: "1", request: { sessionID: fields.sessionID, requestID: fields.requestID }, isDetachRequired: false, previewDigest: "d".repeat(64),
							...(isRelocation ? { operation: "relocate-snippets", role: "snippets", currentBase: "a".repeat(64), preview: { replacement: fields.replacement, baselineRunID: fields.baselineRunID } } : isManagement ? { operation: request?.operation, path: "MEMORY.md", currentBase: "b".repeat(40), before: "", after: Buffer.from(String(request?.replacement ?? "")).toString("base64"), documentBefore: "", replacement: Buffer.from(String(request?.replacement ?? "")).toString("base64") } : { finding: { candidateID: "c".repeat(64), revision: "a".repeat(64), operation: "add" } }),
						};
						native = payload;
						const bytes = Buffer.from(JSON.stringify(payload)); digest = createHash("sha256").update(bytes).digest("hex");
						return { type: isRelocation ? "relocation-presentation" : isManagement ? "manage-presentation" : "presentation", display: isManagement || isRelocation ? { ...payload, displayDigest: digest } : { presentation: payload, displayDigest: digest }, displayBytes: bytes.toString("base64"), displayDigest: digest };
					}
					if (type === "amend") {
						assert.ok(native); assert.equal(isManagement, false); assert.equal(fields.displayDigest, digest); assert.equal(fields.claimID, native.claimID);
						const amendment = fields.amendment as Record<string, string>;
						const replacement = Buffer.from(amendment.replacement!).toString("base64");
						native = { ...native, sequence: String(Number(native.sequence) + 1), after: replacement, replacement, previewDigest: createHash("sha256").update(JSON.stringify(amendment)).digest("hex") };
						const bytes = Buffer.from(JSON.stringify(native)); digest = createHash("sha256").update(bytes).digest("hex");
						return { type: "presentation", display: { presentation: native, displayDigest: digest }, displayBytes: bytes.toString("base64") };
					}
					if (type === "presented" || type === "manage-presented" || type === "relocation-presented") return { type, displayDigest: digest };
					if (type === "reply" || type === "manage-reply" || type === "relocation-reply") {
						const response = responses.shift() ?? "approved";
						if (response === "clarify") return { type: "reply-clarify", status: "no-decision" };
						return { type: isRelocation ? "relocation-decision" : isManagement ? "manage-decision" : "decision", receipt: { decisionID: fields.decisionID, sessionID: fields.sessionID, requestID: fields.requestID, responseReference: fields.responseReference, revision: "a".repeat(64), displayDigest: response === "invalid" ? "0".repeat(64) : digest, status: isRelocation ? "relocated" : "approved", commit: "f".repeat(40), auditRef: "refs/core-memories/unit-audit" } };
					}
					return { type: "released" };
				},
				close: async () => { if (!closes.includes(clientIndex)) closes.push(clientIndex); },
			};
		},
	});
	return {
		...f, frames, signals, closes,
		get displays() { return f.messages.map((message) => String(message.content)); },
		reply: async (text: string, submitted = text, source = "interactive", streamingBehavior?: "steer" | "followUp") => {
			await f.emit("input", { text, source, streamingBehavior });
			await f.emit("before_agent_start", { messageType: "user", prompt: submitted });
			const message = { role: "user", content: submitted, timestamp: 0 };
			await f.emit("message_start", { message });
			f.entries.push({ type: "message", id: "next-user-" + f.entries.length, message });
		},
		call: async (name: string, params: Record<string, unknown>, signal?: AbortSignal) => {
			const tool = f.tools.get(name); assert.ok(tool);
			return tool.execute("unit-call", params, signal, undefined, f.ctx);
		},
	};
}

test("snippet relocation uses the existing durable reply boundary and typed private approval channel", async () => {
	for (const source of ["interactive", "extension"]) {
		const f = conversationalRuntime();
		try {
			await f.emit("session_start");
			const shown = await f.call("memory_queue", { operation: "relocate-snippets", baselineRunID: "synthetic-baseline", replacement: "/synthetic/migrated-snippets" });
			assert.equal((shown.details as Record<string, unknown>).status, "proposal-queued");
			assert.match(f.displays[0]!, /relocate-snippets/);
			assert.match(f.displays[0]!, /\/synthetic\/migrated-snippets/);
			await f.call("memory_queue", { operation: "reply" });
			assert.equal(f.frames.filter((frame) => frame.type === "relocation-reply").length, 0);
			await f.reply("Approve this snippet relocation", undefined, source);
			const result = await f.call("memory_queue", { operation: "reply" });
			assert.equal((result.details as Record<string, unknown>).status, source === "interactive" ? "relocated" : "no-live-conversation-reply");
			const replies = f.frames.filter((frame) => frame.type === "relocation-reply");
			assert.equal(replies.length, source === "interactive" ? 1 : 0);
			if (replies[0]) {
				assert.equal(replies[0].isPrivate, true);
				assert.equal(replies[0].fields.originalText, "Approve this snippet relocation");
				assert.equal(f.frames.find((frame) => frame.type === "relocation-presented")?.isPrivate, true);
			}
		} finally { await f.stop(); }
	}
});

test("relocation receipt mismatch cannot masquerade as memory approval", async () => {
	const f = conversationalRuntime(["invalid"]);
	try {
		await f.emit("session_start");
		await f.call("memory_queue", { operation: "relocate-snippets", baselineRunID: "synthetic-baseline", replacement: "/synthetic/snippets" });
		await f.reply("Approve this snippet relocation");
		const result = await f.call("memory_queue", { operation: "reply" });
		assert.equal((result.details as Record<string, unknown>).status, "outcome-unresolved");
		assert.equal((result.details as Record<string, unknown>).recovery, "relocation-recover");
	} finally { await f.stop(); }
});

test("the same native claim spans a later reply turn without retaining the finished tool signal", async () => {
	const f = conversationalRuntime(); const turn = new AbortController();
	try {
		await f.emit("session_start");
		const proposed = await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) }, turn.signal);
		assert.equal((proposed.details as Record<string, unknown>).status, "proposal-queued");
		assert.doesNotMatch(JSON.stringify(proposed.details), /unit-claim|displayDigest/);
		turn.abort(); assert.equal(f.signals[0]?.aborted, false);
		await f.emit("agent_end"); assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: paused");
		await f.reply("save that memory");
		const saved = await f.call("memory_queue", { operation: "reply" });
		assert.equal((saved.details as Record<string, unknown>).status, "approved");
		const reply = f.frames.find((frame) => frame.type === "reply"); assert.ok(reply);
		assert.equal(reply.fields.originalText, "save that memory"); assert.equal(reply.fields.submittedText, "save that memory");
		assert.equal(reply.isPrivate, true); assert.equal(f.frames.filter((frame) => frame.type === "claim").length, 1);
		assert.equal(f.closes.length, 1);
	} finally { await f.stop(); }
});

test("ambiguous input keeps the same claim and rearms only the native conversation", async () => {
	const f = conversationalRuntime(["clarify", "approved"]);
	try {
		await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await f.reply("yes"); const unclear = await f.call("memory_queue", { operation: "reply" });
		assert.equal((unclear.details as Record<string, unknown>).status, "needs-memory-clarification");
		assert.equal(f.closes.length, 0); assert.equal(f.displays.length, 2);
		await f.reply("save that memory"); await f.call("memory_queue", { operation: "reply" });
		assert.equal(f.frames.filter((frame) => frame.type === "presented").length, 1);
		assert.equal(f.frames.filter((frame) => frame.type === "claim").length, 1);
	} finally { await f.stop(); }
});

test("a candidate amendment keeps its owner and cannot reuse approval for the old display", async () => {
	const f = conversationalRuntime();
	try {
		await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await f.reply("save that memory");
		const changed = await f.call("memory_queue", { operation: "amend", revision: "a".repeat(64), amendment: { replacement: "Revised exact entry. [source: synthetic]", reason: "Revise the proposed wording." } });
		assert.equal((changed.details as Record<string, unknown>).status, "proposal-queued");
		assert.equal((changed.details as Record<string, unknown>).isSaved, false);
		const original = f.frames.find((frame) => frame.type === "presented"); assert.ok(original);
		assert.equal(f.opened.length, 1); assert.equal(f.closes.length, 0);
		assert.equal(f.frames.filter((frame) => frame.type === "claim").length, 1);
		const amendment = f.frames.find((frame) => frame.type === "amend"); assert.ok(amendment);
		assert.notEqual(amendment.isPrivate, true); assert.equal(amendment.fields.originalText, undefined);
		assert.equal(amendment.fields.displayDigest, original.fields.displayDigest);
		assert.equal(f.frames.filter((frame) => frame.type === "presented").length, 1);
		assert.match(f.displays.at(-1)!, /Revised exact entry/);
		await f.emit("agent_end"); assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: paused");
		const premature = await f.call("memory_queue", { operation: "reply" });
		assert.equal((premature.details as Record<string, unknown>).status, "no-live-conversation-reply");
		assert.equal(f.frames.filter((frame) => frame.type === "reply").length, 0);
		await f.reply("save that memory"); const saved = await f.call("memory_queue", { operation: "reply" });
		assert.equal((saved.details as Record<string, unknown>).status, "approved");
		const presented = f.frames.filter((frame) => frame.type === "presented"); assert.equal(presented.length, 2);
		assert.equal(presented[1]!.isPrivate, true); assert.notEqual(presented[1]!.fields.displayDigest, original.fields.displayDigest);
		assert.equal(presented[1]!.fields.claimID, original.fields.claimID);
		const reply = f.frames.find((frame) => frame.type === "reply"); assert.ok(reply);
		assert.equal(reply.isPrivate, true); assert.equal(reply.fields.displayDigest, presented[1]!.fields.displayDigest);
		assert.equal(f.closes.length, 1);
	} finally { await f.stop(); }
});

test("a candidate amendment cannot switch the owned revision", async () => {
	const f = conversationalRuntime();
	try {
		await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await assert.rejects(f.call("memory_queue", { operation: "amend", revision: "b".repeat(64), amendment: { replacement: "Changed entry.", reason: "Revise it." } }), /does not match the live finding/);
		assert.equal(f.frames.filter((frame) => frame.type === "amend" || frame.type === "reply").length, 0);
		assert.equal(f.closes.length, 1);
	} finally { await f.stop(); }
});

test("changing a manual proposal requires a new native preview and a later original reply", async () => {
	const f = conversationalRuntime();
	const first = { base: "b".repeat(40), path: "MEMORY.md", replacement: "first", reason: "User request." };
	try {
		await f.emit("session_start"); await f.call("memory_add", first);
		await f.reply("save that memory"); await f.call("memory_add", { ...first, replacement: "amended" });
		assert.equal(f.closes.length, 1); assert.equal(f.opened.length, 2);
		assert.equal(f.frames.filter((frame) => frame.type === "manage-reply").length, 0);
		const premature = await f.call("memory_add", { ...first, replacement: "amended" });
		assert.equal((premature.details as Record<string, unknown>).status, "no-live-conversation-reply");
		assert.equal(f.displays.length, 2);
		await f.reply("save that memory"); const saved = await f.call("memory_add", { reason: first.reason, replacement: "amended", path: first.path, base: first.base });
		assert.equal((saved.details as Record<string, unknown>).status, "approved");
	} finally { await f.stop(); }
});

test("unrelated next-turn work and session replacement release pending native ownership", async () => {
	const f = conversationalRuntime();
	try {
		await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await f.reply("continue the research"); await f.emit("tool_call", { toolName: "read" });
		assert.equal(f.closes.length, 1); assert.equal(f.frames.filter((frame) => frame.type === "reply").length, 0);
		await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await f.emit("session_before_fork"); assert.equal(f.closes.length, 2);
	} finally { await f.stop(); }
});

test("a pre-append reply cannot authorize after deferred delivery", async () => {
	const f = conversationalRuntime();
	try {
		await f.emit("session_start"); f.deferDelivery();
		await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await f.reply("save that memory"); f.deliver();
		const early = await f.call("memory_queue", { operation: "reply" });
		assert.equal((early.details as Record<string, unknown>).status, "no-live-conversation-reply");
		assert.equal(f.frames.filter((frame) => frame.type === "reply" || frame.type === "presented").length, 0);
		await f.reply("save that memory"); const saved = await f.call("memory_queue", { operation: "reply" });
		assert.equal((saved.details as Record<string, unknown>).status, "approved");
	} finally { await f.stop(); }
});

test("the exact proposal stays visible but is excluded from model context", async () => {
	const f = conversationalRuntime();
	try {
		await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		const user = { role: "user", content: "Explain this finding.", timestamp: 0 };
		const other = { role: "custom", customType: "another-extension", content: "Other message.", timestamp: 0 };
		const messages = [user, { ...f.messages[0], role: "custom", timestamp: 0 }, other];
		const filtered = await f.emit("context", { messages }) as { messages: unknown[] };
		assert.deepEqual(filtered.messages, [user, other]);
		assert.equal(messages.length, 3); assert.equal(f.displays.length, 1);
	} finally { await f.stop(); }
});

for (const operation of ["reply", "amend"]) {
	for (const kind of ["missing", "extension", "rpc", "queued", "transformed", "replaced", "competing"]) {
		test(`${kind} input cannot drive memory ${operation}`, async () => {
			const f = conversationalRuntime();
			try {
				await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
				if (kind === "competing") await f.emit("input", { text: "save that memory", source: "interactive" });
				if (kind !== "missing") await f.reply(kind === "transformed" ? "do not save" : "save that memory", "save that memory", kind === "extension" || kind === "rpc" ? kind : "interactive", kind === "queued" ? "steer" : undefined);
				if (kind === "replaced") f.entries.at(-1)!.message = { ...f.entries.at(-1)!.message };
				const result = await f.call("memory_queue", { operation, ...(operation === "amend" ? { revision: "a".repeat(64), amendment: { replacement: "Changed entry.", reason: "Revise it." } } : {}) });
				assert.equal((result.details as Record<string, unknown>).status, "no-live-conversation-reply");
				assert.equal(f.frames.filter((frame) => frame.type === "reply" || frame.type === "amend" || frame.type === "presented").length, 0);
			} finally { await f.stop(); }
		});
	}
}

test("a mismatched native receipt returns its recovery identifier, never approval", async () => {
	const f = conversationalRuntime(["invalid"]);
	try {
		await f.emit("session_start"); await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		await f.reply("save that memory"); const result = await f.call("memory_queue", { operation: "reply" });
		const details = result.details as Record<string, unknown>;
		assert.equal(details.status, "outcome-unresolved"); assert.equal(typeof details.decisionID, "string");
		assert.equal(details.recovery, "recover"); assert.equal(f.closes.length, 1);
	} finally { await f.stop(); }
});

for (const status of ["approved", "outcome-unresolved"]) {
	test(`recovery reports the native ${status} status without inventing completion`, async () => {
		const receipt = { decisionID: "original-decision", status, ...(status === "approved" ? { commit: "f".repeat(40), auditRef: "refs/core-memories/unit-audit" } : {}) };
		const f = runtime(async () => assert.fail("Recovery must not dispatch a model"), "tui", undefined, {
			open: async () => ({ request: async (type, fields, isPrivate) => {
				assert.equal(type, "recover"); assert.equal(fields?.decisionID, receipt.decisionID); assert.notEqual(isPrivate, true);
				return { type: "decision", receipt };
			}, close: async () => {} }),
		});
		try {
			await f.emit("session_start");
			const result = await f.tool.execute("recover-native", { operation: "recover", decisionID: receipt.decisionID }, undefined, undefined, f.ctx);
			assert.deepEqual(result.details, { receipt, status });
		} finally { await f.stop(); }
	});
}
