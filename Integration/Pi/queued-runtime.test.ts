import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { after, test } from "node:test";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Extension, ExtensionAPI, ExtensionContext, ExtensionToolContext, ModelRegistry, SessionManager, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { DreamReport, DreamRequest, DreamStart, runDreamWorker } from "./dream.ts";
import type { openQueueClient } from "./queue-client.ts";
import "./test/host.ts";
const { memoryRequestIdentity, registerQueuedRuntime, assertArchivedRequest } = await import("./queued-runtime.ts");
const { ExtensionRunner, createExtensionRuntime } = await import("@earendil-works/pi-coding-agent");
const stateDirectory = await mkdtemp(join(tmpdir(), "pi-core-memories-runtime-"));
after(() => rm(stateDirectory, { recursive: true, force: true }));
type TestEntry = Partial<Parameters<ExtensionAPI["sendMessage"]>[0]> & { type: string; id: string; message: { role: string; content?: string; timestamp?: number } };
function context() {
	const entries: TestEntry[] = [{ type: "message", id: "user-entry", message: { role: "user", content: "Start the conversation.", timestamp: 0 } }];
	const statuses = new Map<string, string>();
	const ui = { setStatus(key: string, value: string | undefined) { if (value === undefined) statuses.delete(key); else statuses.set(key, value); } };
	const ctx = { ui, mode: "tui", hasUI: true, cwd: "/synthetic", model: { provider: "openai-codex", id: "selected", contextWindow: 262_144 }, thinkingLevel: "high", isIdle: () => true, hasPendingMessages: () => false, sessionManager: { getSessionId: () => "session", getSessionFile: () => "/sessions/session.jsonl", getBranch: () => entries } } as unknown as ExtensionContext;
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
		roots: async () => ({ state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }), scope: async () => ({}), liveDirectory: stateDirectory, ...overrides });
	return { ctx, entries, stop, opened, marks, unmarks, peers, closed, tools, messages, statuses, handlers,
		deferDelivery: () => { isDeliveryDeferred = true; },
		deliver: () => { isDeliveryDeferred = false; for (const message of pending.splice(0)) append(message); },
		get tool() { assert.ok(registeredTool); return registeredTool; },
		emit: async (name: string, event: unknown = {}) => handlers.get(name)?.(event, ctx) };
}
async function until(condition: () => boolean | Promise<boolean>, failure: string): Promise<void> {
	for (const deadline = Date.now() + 5_000; !(await condition()); await sleep(1)) if (Date.now() > deadline) assert.fail(failure);
}
const archivedRequest = (start: DreamStart, session = "archived"): DreamRequest => ({ version: 1, type: "modelRequest", invocationID: start.invocationID, requestID: "request", runID: "run", generation: "1", inputHash: "a".repeat(64), contextHash: "b".repeat(64), requestHash: "c".repeat(64), selection: start.selection, systemPrompt: "Synthetic status test", messages: [{ role: "user", text: JSON.stringify({ primaryEvidence: [{ source: { session, entry: "entry", part: 0 } }] }), timestampMilliseconds: 0 }] });

test("dreaming keeps running while this window works and reports the blocked reason without details", async () => {
	let enter!: () => void; const entered = new Promise<void>((resolve) => { enter = resolve; });
	let release!: () => void; const released = new Promise<void>((resolve) => { release = resolve; });
	let runs = 0; let workerSignal: AbortSignal | undefined; let blockedInvocationID = "";
	const f = runtime(async (start, call, signal) => {
		runs++; workerSignal = signal;
		if (runs > 1) { blockedInvocationID = start.invocationID; return { status: "blocked", reason: "sourceProtection:invalidReply", detail: "PRIVATE_DETAIL" } as DreamReport; }
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
		const path = join(stateDirectory, "last-dream-blocked.json");
		release(); await until(() => stat(path).then(() => true, () => false), "No blocked report");
		assert.equal(runs, 2);
		assert.equal(f.statuses.get("pi-core-memories:dream"), 'dreaming: error(code: blocked, reason: sourceProtection:invalidReply, message: "Native dream worker blocked the run")');
		assert.equal((await stat(path)).mode & 0o777, 0o600);
		const { time, ...recorded } = JSON.parse(await readFile(path, "utf8"));
		assert.ok(!Number.isNaN(Date.parse(time)));
		assert.deepEqual(recorded, { invocationID: blockedInvocationID, status: "blocked", reason: "sourceProtection:invalidReply", detail: "PRIVATE_DETAIL" });
	} finally { await f.stop(); }
	assert.equal(f.statuses.has("pi-core-memories:dream"), false);
});

for (const mode of ["print", "rpc"]) {
	test(`a ${mode} session with a session file writes a live marker but never dreams`, async () => {
		const f = runtime(async () => assert.fail("Non-interactive sessions must not dream"), mode);
		try { await f.emit("session_start"); await until(() => f.marks.length > 0, "No live marker"); assert.deepEqual(f.marks, ["session"]); }
		finally { await f.stop(); }
		assert.deepEqual(f.unmarks, ["session"]);
	});
}

test("the footer combines dream state with the nonzero review count from the native queue", async () => {
	let release!: () => void; const released = new Promise<void>((resolve) => { release = resolve; });
	const seen: string[] = [];
	const f = runtime(async () => { await released; return { status: "noNewRecords" } as DreamReport; }, "tui", undefined, {
		open: async () => ({ request: async (type: string) => { seen.push(f.statuses.get("pi-core-memories:dream")!); assert.equal(type, "counts"); return { type: "counts", review: 2 }; }, close: async () => {} }) as unknown as Awaited<ReturnType<typeof openQueueClient>>,
	});
	try {
		await f.emit("session_start");
		await until(() => f.statuses.get("pi-core-memories:dream") === "dreaming: active \u00b7 2 to review", "No review count in the footer");
		assert.equal(seen[0], "dreaming: active");
	} finally { release(); await f.stop(); }
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
		await f.emit("session_start");
		await until(() => /error\(code: workerFailure,/.test(f.statuses.get("pi-core-memories:dream") ?? ""), "No worker failure");
		assert.deepEqual(excluded.slice(0, 2), ["another-live-session", "session"]);
		assert.equal(calls, 0);
		assert.match(f.statuses.get("pi-core-memories:dream")!, /error\(code: workerFailure,/);
	} finally { await f.stop(); }
});

function footerHistory(ctx: ExtensionContext): (string | undefined)[] {
	const history: (string | undefined)[] = []; const setStatus = ctx.ui.setStatus.bind(ctx.ui);
	Object.assign(ctx.ui, { setStatus: (key: string, value: string | undefined) => { history.push(value); setStatus(key, value); } });
	return history;
}

test("an interrupted call after a restart is retried under its recorded selection instead of pausing dreaming forever", async () => {
	const starts: DreamStart[] = []; let calls = 0;
	const f = runtime(async (start, call, signal) => {
		starts.push(start);
		if (starts.length === 1) return { status: "pending", reason: "interruptedCall", callSelection: start.selection } as DreamReport;
		if (start.resume === "retryInterruptedCall") await call(archivedRequest(start), signal);
		return { status: start.resume === "retryInterruptedCall" ? "completed" : "noNewRecords" } as DreamReport;
	}, "tui", undefined, { call: async () => { calls++; return "{}"; } });
	const footer = footerHistory(f.ctx);
	try {
		await f.emit("session_start");
		await until(() => calls === 1 && f.statuses.get("pi-core-memories:dream") === "dreaming: idle", "No retried call");
		assert.deepEqual(starts.slice(0, 2).map((start) => start.resume), ["inspectOrContinue", "retryInterruptedCall"]);
		assert.deepEqual(starts[1]!.selection, starts[0]!.selection);
		assert.equal(calls, 1);
		assert.ok(!footer.includes("dreaming: paused"));
		assert.equal(f.statuses.get("pi-core-memories:dream"), "dreaming: idle");
	} finally { await f.stop(); }
});

test("an interrupted call is never retried under another selection and shows its recorded model until the window switches back", async () => {
	const recorded = { provider: "anthropic", modelID: "recorded", thinkingLevel: "low" };
	const starts: DreamStart[] = [];
	const f = runtime(async (start) => {
		starts.push(start);
		return (start.resume === "retryInterruptedCall" ? { status: "completed" } : { status: "pending", reason: "interruptedCall", callSelection: recorded }) as DreamReport;
	});
	const footer = footerHistory(f.ctx);
	try {
		await f.emit("session_start");
		await until(() => f.statuses.get("pi-core-memories:dream")?.startsWith("dreaming: error(code: interruptedCall,") ?? false, "No interrupted call status");
		assert.deepEqual(starts.map((start) => start.resume), ["inspectOrContinue"]);
		assert.equal(f.statuses.get("pi-core-memories:dream"), 'dreaming: error(code: interruptedCall, message: "Interrupted dream needs the model it started with: anthropic/recorded, thinking low")');
		Object.assign(f.ctx, { model: { provider: "anthropic", id: "recorded", contextWindow: 262_144 }, thinkingLevel: "low" });
		await f.emit("model_select");
		await until(() => starts.length >= 3, "No retry under the recorded selection");
		assert.deepEqual(starts.slice(0, 3).map((start) => start.resume), ["inspectOrContinue", "inspectOrContinue", "retryInterruptedCall"]);
		assert.deepEqual(starts[2]!.selection, recorded);
		assert.ok(!footer.includes("dreaming: paused"));
	} finally { await f.stop(); }
});


test("pending and present run the verified queue work once, with at most one count refresh after it", async () => {
	const f = conversationalRuntime();
	try {
		await f.emit("session_start");
		await f.call("memory_queue", { operation: "pending" });
		assert.deepEqual(f.frames.map((frame) => frame.type), ["list", "counts"]);
		f.frames.length = 0;
		await f.call("memory_queue", { operation: "present", revision: "a".repeat(64) });
		assert.deepEqual(f.frames.map((frame) => frame.type), ["claim"]);
	} finally { await f.stop(); }
});

function conversationalRuntime(responses: ("approved" | "clarify" | "invalid" | "deferred" | "rejected")[] = [], rows: unknown[] | (() => unknown[]) = [], overrides: NonNullable<Parameters<typeof registerQueuedRuntime>[1]> = {}) {
	let f: ReturnType<typeof runtime>;
	const frames: { type: string; fields: Record<string, unknown>; isPrivate?: boolean }[] = [];
	const signals: AbortSignal[] = []; const closes: number[] = [];
	f = runtime(async () => assert.fail("A native conversation must prevent background dispatch"), "tui", undefined, {
		idleMilliseconds: 60_000,
		open: async (directory, signal) => {
			assert.ok(signal);
			let isManagement = false; let isRelocation = false; let digest = ""; let native: Record<string, unknown> | undefined; let clientIndex = 0;
			return {
				signal,
				request: async (type, fields = {}, isPrivate) => {
					frames.push({ type, fields, isPrivate });
					if (type === "counts") return { type: "counts", review: 0 };
					if (type === "list") return { type: "queue", rows: typeof rows === "function" ? rows() : rows, nextOffset: null };
					if (!clientIndex) { signals.push(signal); f.opened.push([directory, signal]); clientIndex = signals.length; }
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
						return { type: isRelocation ? "relocation-decision" : isManagement ? "manage-decision" : "decision", receipt: { decisionID: fields.decisionID, sessionID: fields.sessionID, requestID: fields.requestID, responseReference: fields.responseReference, revision: "a".repeat(64), displayDigest: response === "invalid" ? "0".repeat(64) : digest, status: isRelocation ? "relocated" : response === "deferred" || response === "rejected" ? response : "approved", commit: "f".repeat(40), auditRef: "refs/core-memories/unit-audit" } };
					}
					return { type: "released" };
				},
				close: async () => { if (clientIndex && !closes.includes(clientIndex)) closes.push(clientIndex); },
			};
		},
		...overrides,
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

const pendingRow = (revision: string, proposed: string, disposition = "pending", blockReason?: string) => ({ finding: { revision, proposed: Buffer.from(proposed).toString("base64") }, disposition, ...blockReason ? { blockReason } : {} });
type ContextMessage = { role: string; customType?: string; content?: unknown; timestamp?: number };
function reminderTurns(f: ReturnType<typeof runtime>, transcript: ContextMessage[] = [{ role: "user", content: "Earlier request.", timestamp: 1 }, { role: "assistant", content: [], timestamp: 2 }]) {
	const runner = new ExtensionRunner([{ path: "queued-runtime", handlers: new Map([...f.handlers].map(([name, handler]) => [name, [handler]])) } as unknown as Extension], createExtensionRuntime(), "/synthetic", f.ctx.sessionManager as unknown as SessionManager, {} as ModelRegistry);
	runner.onError((error) => assert.fail(error.error));
	let clock = transcript.at(-1)?.timestamp ?? 0;
	const request = async () => {
		const messages = await runner.emitContext(transcript as AgentMessage[]) as ContextMessage[];
		const next = messages[messages.findLastIndex((message) => message.role === "user") + 1];
		return { messages, transcript, reminder: next?.customType === "pi-core-memories:pending-reminder" ? String(next.content) : undefined };
	};
	return Object.assign(async (prompt = "Check the synthetic build settings.") => {
		await f.emit("before_agent_start", { messageType: "user", prompt });
		transcript.push({ role: "user", content: prompt, timestamp: ++clock }, { role: "toolResult", content: [], timestamp: ++clock });
		return request();
	}, { request });
}
function reminderRuntime(rows: () => unknown[], fail?: Error, mode = "tui") {
	return runtime(async () => ({ status: "pending" }) as DreamReport, mode, undefined, { idleMilliseconds: 60_000,
		open: async () => ({ request: async (type) => { if (fail) throw fail; return type === "list" ? { type: "queue", rows: rows(), nextOffset: null } : { type: "released" }; }, close: async () => {} }) });
}

test("a pending finding the user's request could match reaches the model each turn, and decided findings do not", async () => {
	const pending = "a".repeat(64);
	const rows = [pendingRow(pending, "The synthetic build host uses the staging profile.\nSecond line."), pendingRow("b".repeat(64), "Deferred earlier.", "deferred"), pendingRow("c".repeat(64), "Approved already.", "approved"), pendingRow("d".repeat(64), "Rejected already.", "rejected"), pendingRow("e".repeat(64), "Decision unresolved.", "pending", "outcome-unresolved")];
	const f = reminderRuntime(() => rows);
	try {
		await f.emit("session_start");
		const { reminder } = await reminderTurns(f)();
		assert.ok(reminder);
		assert.match(reminder, /memory_queue present/); assert.match(reminder, /not approval/); assert.match(reminder, /Only the latest pending-findings reminder is current/);
		assert.match(reminder, new RegExp(`- ${pending}: The synthetic build host uses the staging profile\.\n- ${"b".repeat(64)}: Deferred earlier\.$`));
		assert.doesNotMatch(reminder, /Second line|Approved|Rejected|unresolved/);
	} finally { await f.stop(); }
});

test("a slow pending reminder keeps its own worker alive past the turn's wait and through user input, and the next turn reuses it for the late reminder", async () => {
	const signals: AbortSignal[] = [];
	let lists = 0;
	let release!: () => void; const released = new Promise<void>((resolve) => { release = resolve; });
	const rows = [pendingRow("a".repeat(64), "Late synthetic claim.")];
	const f = runtime(async () => ({ status: "pending" }) as DreamReport, "tui", undefined, { idleMilliseconds: 60_000, reminderWaitMilliseconds: 200,
		open: async (_directory, signal) => {
			signals.push(signal);
			return { request: async (type) => {
				if (type !== "list") return { type: "counts", review: 0 };
				const call = ++lists;
				if (call === 1) await released;
				if (call === 2) await new Promise<never>((_resolve, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
				return { type: "queue", rows, nextOffset: null };
			}, close: async () => {} };
		} });
	try {
		await f.emit("session_start");
		const turn = reminderTurns(f);
		assert.equal((await turn()).reminder, undefined);
		await f.emit("input", { text: "Next request.", source: "interactive" });
		await sleep(0);
		assert.equal(lists, 1);
		assert.equal(signals.length, 1); assert.equal(signals[0]!.aborted, false);
		const late = turn();
		await sleep(10);
		assert.equal(lists, 1);
		release();
		assert.match((await late).reminder!, /Late synthetic claim\./);
		assert.equal(lists, 1); assert.equal(signals.length, 1);
	} finally { release(); await f.stop(); }
});

function hangingReminderRuntime(isCloseHeld = false) {
	const reminder: { signal?: AbortSignal; isClosed: boolean } = { isClosed: false };
	let releaseClose!: () => void; const closeReleased = new Promise<void>((resolve) => { releaseClose = resolve; });
	if (!isCloseHeld) releaseClose();
	let opens = 0;
	const f = runtime(async () => ({ status: "pending" }) as DreamReport, "tui", undefined, { idleMilliseconds: 60_000, reminderWaitMilliseconds: 20,
		open: async (_directory, signal) => {
			const isReminder = ++opens === 1;
			if (isReminder) reminder.signal = signal;
			return {
				request: async (type) => {
					if (isReminder) return new Promise<never>((_resolve, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
					return type === "list" ? { type: "queue", rows: [], nextOffset: null } : { type: "counts", review: 0 };
				},
				close: async () => { if (isReminder) { await closeReleased; reminder.isClosed = true; } },
			};
		} });
	return { f, reminder, releaseClose };
}
const promptly = <T>(operation: Promise<T>) => Promise.race([operation, sleep(1_000).then(() => assert.fail("The memory tool call waited behind the pending reminder."))]);

test("a memory tool call stops a hanging pending reminder read instead of waiting behind it", async () => {
	const { f, reminder } = hangingReminderRuntime();
	try {
		await f.emit("session_start");
		assert.equal((await reminderTurns(f)()).reminder, undefined);
		assert.equal(reminder.signal?.aborted, false);
		await promptly(f.tool.execute("during-reminder", { operation: "pending" }, undefined, undefined, f.ctx));
		assert.equal(reminder.signal?.aborted, true); assert.equal(reminder.isClosed, true);
	} finally { await f.stop(); }
});

for (const cancellation of ["tool abort", "user input"] as const) {
	test(`a ${cancellation} ends a memory tool call promptly while the stopped reminder worker is still closing`, async () => {
		const { f, reminder, releaseClose } = hangingReminderRuntime(true);
		try {
			await f.emit("session_start");
			await reminderTurns(f)();
			const controller = new AbortController();
			const call = f.tool.execute("cancelled", { operation: "pending" }, controller.signal, undefined, f.ctx);
			await until(() => reminder.signal?.aborted === true, "The reminder read was not stopped");
			assert.equal(reminder.isClosed, false);
			if (cancellation === "tool abort") controller.abort(); else await f.emit("input", { text: "Stop that.", source: "interactive" });
			await promptly(assert.rejects(call));
			releaseClose();
			await sleep(0);
			assert.equal(reminder.isClosed, true);
		} finally { releaseClose(); await f.stop(); }
	});
}

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

