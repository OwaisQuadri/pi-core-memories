import { createHash, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { getAgentDir, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { callDreamModel, dreamBatchTextBytes, dreamRoots, readDreamScope, runDreamWorker, type DreamRequest, type DreamSelection, type DreamStart } from "./dream.ts";
import { openQueueClient, queueObject, type QueueObject } from "./queue-client.ts";
import { protectDreamSources } from "./source-protection.ts";
import { joinInteractiveMembership, type InteractiveMembership } from "./interactive-membership.ts";

const hash = (value: string): string => createHash("sha256").update(value).digest("hex");
export function memoryRequestIdentity(ctx: Pick<ExtensionContext, "sessionManager">): { sessionID: string; requestID: string } {
	const entry = [...ctx.sessionManager.getBranch()].reverse().find((entry) => entry.type === "message" && entry.message.role === "user");
	if (!entry) throw new Error("Memory review needs a durable user request on the current branch.");
	return { sessionID: hash(ctx.sessionManager.getSessionId()), requestID: hash(entry.id) };
}
export function assertArchivedRequest(request: DreamRequest, sessionID: string | string[]): void {
	const excluded = new Set(typeof sessionID === "string" ? [sessionID] : sessionID);
	for (const message of request.messages) {
		if (message.role !== "user") continue;
		const payload = queueObject(JSON.parse(message.text));
		if (!Array.isArray(payload.primaryEvidence)) throw new Error("Archived memory input could not be verified.");
		const containsSession = (value: unknown): boolean => {
			if (!value || typeof value !== "object") return false;
			if (Array.isArray(value)) return value.some(containsSession);
			const object = value as QueueObject;
			return (typeof object.session === "string" && excluded.has(object.session)) || Object.values(object).some(containsSession);
		};
		if (containsSession(payload)) throw new Error("The memory batch includes this active session. Archived-only admission is required before model dispatch.");
	}
}

type RuntimeDependencies = {
	open: typeof openQueueClient;
	run: typeof runDreamWorker;
	roots: typeof dreamRoots;
	scope: typeof readDreamScope;
	call: typeof callDreamModel;
	protect: typeof protectDreamSources;
	idleMilliseconds: number;
	membership: typeof joinInteractiveMembership;
	membershipDirectory: string;
};
export function registerQueuedRuntime(pi: ExtensionAPI, overrides: Partial<RuntimeDependencies> = {}): () => Promise<void> {
	const deps: RuntimeDependencies = { open: openQueueClient, run: runDreamWorker, roots: dreamRoots, scope: readDreamScope, call: callDreamModel, protect: protectDreamSources, idleMilliseconds: 30_000, membership: joinInteractiveMembership, membershipDirectory: join(homedir(), ".pi", "memory-host"), ...overrides };
	let context: ExtensionContext | undefined;
	let membership: InteractiveMembership | undefined;
	let background: AbortController | undefined;
	let backgroundCompletion: Promise<void> | undefined;
	let foreground: AbortController | undefined;
	let foregroundCompletion: Promise<unknown> | undefined;
	let timer: ReturnType<typeof setTimeout> | undefined;
	let isAlive = false;
	let isWorking = false;
	let failures = 0;
	let generation = 0;
	function stopBackground(): void { clearTimeout(timer); timer = undefined; background?.abort(); }
	function invalidate(): void { generation++; foreground?.abort(); stopBackground(); }
	function updateMembership(): void {
		if (context) membership?.set({ sessionID: context.sessionManager.getSessionId(), isForeground: isWorking || !!foreground || context.hasPendingMessages() });
	}
	async function leaveMembership(): Promise<void> { const previous = membership; membership = undefined; await previous?.close(); }
	function schedule(): void {
		clearTimeout(timer);
		if (!isAlive || !membership || isWorking || foreground || !context || failures >= 3) return;
		timer = setTimeout(() => { timer = undefined; void startBackground(); }, deps.idleMilliseconds * 2 ** failures);
		timer.unref?.();
	}
	async function startBackground(): Promise<void> {
		const ctx = context;
		if (!ctx || !isAlive || isWorking || foreground || background || !ctx.isIdle() || ctx.hasPendingMessages()) { schedule(); return; }
		const model = ctx.model;
		if (!model || !["openai", "openai-codex", "anthropic"].includes(model.provider)) return;
		const batchTextBytes = dreamBatchTextBytes(model.contextWindow);
		if (batchTextBytes === null) return;
		const selection: DreamSelection = { provider: model.provider, modelID: model.id, thinkingLevel: ctx.thinkingLevel ?? pi.getThinkingLevel() };
		const current = new AbortController(); background = current;
		const sessionID = ctx.sessionManager.getSessionId();
		backgroundCompletion = (async () => {
			try {
				const live = membership;
				if (!live) return;
				updateMembership();
				const admitted = await live.snapshot();
				if (admitted.isForeground || !admitted.sessionIDs.length || admitted.sessionIDs.length > 64) return;
				const roots = await deps.roots(getAgentDir(), ctx.cwd);
				const scope = await deps.scope(current.signal);
				current.signal.throwIfAborted();
				const invocationID = randomUUID();
				const start: DreamStart & { excludedSessionIDs: string[] } = { version: 1, type: "start", invocationID, roots, selection, resume: "inspectOrContinue", batchTextBytes, ...scope, excludedSessionIDs: admitted.sessionIDs };
				const report = await deps.run(start, async (request, signal) => {
					if (!isAlive || isWorking || current.signal.aborted || ctx.sessionManager.getSessionId() !== sessionID || ctx.model?.id !== model.id || ctx.model?.provider !== model.provider || (ctx.thinkingLevel ?? pi.getThinkingLevel()) !== selection.thinkingLevel) throw new Error("Memory worker selection or lifecycle changed.");
					const currentMembers = await live.snapshot();
					if (currentMembers.isForeground || membership !== live || JSON.stringify(currentMembers.sessionIDs) !== JSON.stringify(admitted.sessionIDs) || signal.aborted || current.signal.aborted) throw new Error("Interactive memory membership changed.");
					assertArchivedRequest(request, currentMembers.sessionIDs);
					return deps.call(request, ctx, model, selection, signal);
				}, current.signal, () => {}, (value: unknown, signal: AbortSignal) => deps.protect(pi, invocationID, value, signal));
				if (["blocked", "pending"].includes(report.status)) failures = 3;
				else if (report.status === "busy") failures++;
				else failures = 0;
			} catch { if (!current.signal.aborted) failures++; }
			finally { if (background === current) background = undefined; schedule(); }
		})();
		await backgroundCompletion;
	}
	pi.on("session_start", async (_event, ctx) => {
		invalidate(); const epoch = generation; await leaveMembership();
		if (generation !== epoch) return;
		context = ctx; isAlive = ctx.mode === "tui" && ctx.hasUI; isWorking = !ctx.isIdle(); failures = 0;
		if (!isAlive) return;
		try {
			const joined = await deps.membership(deps.membershipDirectory, { sessionID: ctx.sessionManager.getSessionId(), isForeground: isWorking }, () => { stopBackground(); schedule(); });
			if (generation !== epoch || !isAlive) { await joined.close(); return; }
			membership = joined;
		} catch { return; }
		updateMembership(); schedule();
	});
	pi.on("input", () => { invalidate(); failures = 0; isWorking = true; updateMembership(); });
	pi.on("before_agent_start", () => { stopBackground(); isWorking = true; updateMembership(); });
	pi.on("agent_end", (_event, ctx) => { context = ctx; isWorking = false; updateMembership(); schedule(); });
	pi.on("tool_execution_start", () => { stopBackground(); updateMembership(); });
	pi.on("model_select", (_event, ctx) => { invalidate(); context = ctx; failures = 0; schedule(); });
	pi.on("thinking_level_select", (_event, ctx) => { invalidate(); context = ctx; failures = 0; schedule(); });
	pi.on("session_before_switch", async () => { isAlive = false; invalidate(); await leaveMembership(); });
	pi.on("session_before_fork", async () => { isAlive = false; invalidate(); await leaveMembership(); });
	pi.on("session_before_tree", () => { invalidate(); isWorking = true; updateMembership(); });
	pi.on("session_before_compact", () => { invalidate(); isWorking = true; updateMembership(); });
	pi.on("session_tree", (_event, ctx) => { context = ctx; isWorking = !ctx.isIdle(); updateMembership(); schedule(); });
	pi.on("session_compact", (_event, ctx) => { context = ctx; isWorking = !ctx.isIdle(); updateMembership(); schedule(); });
	pi.on("session_compact_failed", (_event, ctx) => { context = ctx; isWorking = !ctx.isIdle(); updateMembership(); schedule(); });
	const stop = async () => { isAlive = false; invalidate(); await leaveMembership(); await Promise.allSettled([backgroundCompletion, foregroundCompletion]); };
	pi.on("session_shutdown", stop);
	pi.registerTool({
		name: "memory_queue", label: "Memory queue", executionMode: "sequential",
		description: "Inspect pending findings, retained migration inventory and approved memories during ordinary conversation. This tool cannot approve or change memory and never opens a review dialog. The ordinary-chat approval transport is not complete. Recovery only checks an existing decision; it never replays consent.",
		parameters: Type.Object({
			operation: Type.Union([Type.Literal("pending"), Type.Literal("inventory"), Type.Literal("approved-list"), Type.Literal("approved-get"), Type.Literal("recover"), Type.Literal("manage-recover")]),
			offset: Type.Optional(Type.String({ pattern: "^(0|[1-9][0-9]{0,9})$" })),
			request: Type.Optional(Type.Object({}, { additionalProperties: true, description: "Exact approved-memory get request: operation, base, path, locator and expected. Obtain exact fields from approved-list." })),
			decisionID: Type.Optional(Type.String({ pattern: "^[A-Za-z0-9._:-]{1,256}$" })),
		}, { additionalProperties: false }),
		async execute(_id, params, signal, _update, ctx) {
			if (ctx.mode !== "tui" || !ctx.hasUI || !isAlive || foreground) throw new Error("Memory queue needs one live interactive session.");
			const identity = memoryRequestIdentity(ctx);
			const current = new AbortController(); foreground = current; updateMembership();
			const combined = AbortSignal.any(signal ? [signal, current.signal] : [current.signal]);
			const epoch = generation;
			const isCurrent = () => {
				try { return isAlive && generation === epoch && !combined.aborted && JSON.stringify(memoryRequestIdentity(ctx)) === JSON.stringify(identity); }
				catch { return false; }
			};
			stopBackground();
			foregroundCompletion = (async () => {
				await backgroundCompletion;
				combined.throwIfAborted();
				if (!isCurrent()) throw new Error("Memory request changed before ownership was acquired.");
				const client = await deps.open(ctx.cwd, combined);
				try {
					const operation = params.operation === "pending" ? "list" : params.operation;
					const fields = operation === "list" ? { ...identity, offset: params.offset ?? "0" } : operation === "approved-get" ? { request: params.request } : operation === "recover" || operation === "manage-recover" ? { decisionID: params.decisionID } : {};
					const result = await client.request(operation, fields);
					if (operation === "recover" || operation === "manage-recover") return { receipt: result.receipt ?? null, status: result.type === "blocked" ? "outcome-unresolved" : "recovered" };
					const { invocationID: _invocation, version: _version, ...publicResult } = result;
					return publicResult;
				} finally { await client.close(); }
			})();
			try {
				const result = await foregroundCompletion;
				return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
			} finally { if (foreground === current) foreground = undefined; updateMembership(); schedule(); }
		},
	});
	return stop;
}
