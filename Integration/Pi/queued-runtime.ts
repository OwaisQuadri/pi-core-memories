import { createHash, randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { Type, type UserMessage } from "@earendil-works/pi-ai";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext, SessionEntry } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { callDreamModel, dreamBatchTextBytes, dreamRoots, readDreamScope, runDreamWorker, type DreamRequest, type DreamSelection, type DreamStart } from "./dream.ts";
import { decodeQueuePreview, openQueueClient, queueObject, type QueueConnection, type QueueObject, type QueuePreview } from "./queue-client.ts";
import { registerMemoryManagement } from "./management.ts";
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

type MemoryConversationState = {
	client: QueueConnection;
	controller: AbortController;
	owner: string;
	identity: ReturnType<typeof memoryRequestIdentity>;
	startType: "claim" | "manage-preview";
	startFields: QueueObject;
	preview: QueuePreview;
	proposalId: string;
	presentedForRequest: string;
	isAcknowledged: boolean;
};
type MemoryReplyInput = {
	proposalId: string;
	proposalEntryId: string;
	previousLeafId: string;
	text: string;
	isRunStarted: boolean;
	message?: UserMessage;
};
function userText(message: UserMessage): string | undefined {
	if (typeof message.content === "string") return message.content;
	return message.content.length === 1 && message.content[0]?.type === "text" ? message.content[0].text : undefined;
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
	let conversation: MemoryConversationState | undefined;
	let observedReply: MemoryReplyInput | undefined;
	let conversationClose = Promise.resolve();
	pi.registerMessageRenderer("pi-core-memories:proposal", (message) => typeof message.content === "string" ? new Text(message.content, 0, 0) : undefined);
	function closeConversation(): Promise<void> {
		const previous = conversation; conversation = undefined; observedReply = undefined;
		if (previous) { previous.controller.abort(); conversationClose = previous.client.close(); }
		return conversationClose;
	}
	function stopBackground(): void { clearTimeout(timer); timer = undefined; background?.abort(); }
	function invalidate(isConversationInvalidated = true): void {
		foreground?.abort(); stopBackground();
		if (isConversationInvalidated) { generation++; void closeConversation(); }
	}
	function updateMembership(): void {
		if (context) membership?.set({ sessionID: context.sessionManager.getSessionId(), isForeground: isWorking || !!foreground || !!conversation || context.hasPendingMessages() });
	}
	async function leaveMembership(): Promise<void> { const previous = membership; membership = undefined; await previous?.close(); }
	function schedule(): void {
		clearTimeout(timer);
		if (!isAlive || !membership || isWorking || foreground || conversation || !context || failures >= 3) return;
		timer = setTimeout(() => { timer = undefined; void startBackground(); }, deps.idleMilliseconds * 2 ** failures);
		timer.unref?.();
	}
	async function startBackground(): Promise<void> {
		const ctx = context;
		if (!ctx || !isAlive || isWorking || foreground || conversation || background || !ctx.isIdle() || ctx.hasPendingMessages()) { schedule(); return; }
		const model = ctx.model;
		if (!model || !["openai", "openai-codex", "anthropic"].includes(model.provider)) return;
		const batchTextBytes = dreamBatchTextBytes(model.contextWindow);
		if (batchTextBytes === null) return;
		const selection: DreamSelection = { provider: model.provider, modelID: model.id, thinkingLevel: ctx.thinkingLevel ?? pi.getThinkingLevel() };
		const current = new AbortController(); background = current;
		const sessionID = ctx.sessionManager.getSessionId();
		backgroundCompletion = (async () => {
			try {
				await conversationClose;
				current.signal.throwIfAborted();
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
	function conversationEntry(state: MemoryConversationState, ctx: ExtensionContext): SessionEntry | undefined {
		let match: SessionEntry | undefined;
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type !== "custom_message" || entry.customType !== "pi-core-memories:proposal" || entry.display !== true || entry.content !== state.preview.details || !entry.details || typeof entry.details !== "object" || !("proposalId" in entry.details) || entry.details.proposalId !== state.proposalId) continue;
			if (match) return;
			match = entry;
		}
		return match;
	}
	function takeConversationReply(state: MemoryConversationState, ctx: ExtensionContext, requestID: string): MemoryReplyInput | undefined {
		const reply = observedReply; observedReply = undefined;
		if (!reply || !reply.isRunStarted || !reply.message || reply.proposalId !== state.proposalId || requestID === state.presentedForRequest || conversationEntry(state, ctx)?.id !== reply.proposalEntryId) return;
		const branch = ctx.sessionManager.getBranch();
		const prior = branch.findIndex((entry) => entry.id === reply.previousLeafId);
		const users = branch.filter((entry, index) => index > prior && entry.type === "message" && entry.message.role === "user");
		const user = users[0];
		if (prior < 0 || users.length !== 1 || !user || user.type !== "message" || user.message !== reply.message || userText(reply.message) !== reply.text) return;
		return reply;
	}
	async function acknowledgeConversation(state: MemoryConversationState, ctx: ExtensionContext): Promise<void> {
		const entry = conversationEntry(state, ctx);
		if (!entry) throw new Error("The exact memory proposal has not been appended to this conversation. Nothing was approved.");
		if (state.isAcknowledged) return;
		const type = state.preview.isManagement ? "manage-presented" : "presented";
		const ack = await state.client.request(type, { ...state.preview.tuple, messageReference: entry.id }, true);
		if (ack.type !== type || ack.displayDigest !== state.preview.digest) throw new Error("Native memory presentation was not acknowledged. Nothing was approved.");
		state.isAcknowledged = true;
	}
	async function showConversation(state: MemoryConversationState, requestID: string, isFirst: boolean): Promise<void> {
		observedReply = undefined;
		state.proposalId = randomUUID(); state.presentedForRequest = requestID;
		if (isFirst) state.isAcknowledged = false;
		pi.sendMessage({ customType: "pi-core-memories:proposal", content: state.preview.details, display: true, details: { proposalId: state.proposalId } }, { triggerTurn: false });
	}
	async function refreshConversation(state: MemoryConversationState, requestID: string): Promise<QueueObject> {
		const frame = await state.client.request(state.startType, { ...state.startFields, ...state.identity });
		if (frame.type !== (state.startType === "claim" ? "presentation" : "manage-presentation")) {
			const { invocationID: _invocation, version: _version, ...publicResult } = frame;
			return publicResult;
		}
		state.preview = decodeQueuePreview(frame, state.identity);
		await showConversation(state, requestID, true);
		return { status: "proposal-queued", tool: state.owner };
	}
	async function perform(owner: string, operation: string, params: QueueObject, signal: AbortSignal | undefined, ctx: ExtensionToolContext): Promise<unknown> {
		if (ctx.mode !== "tui" || !ctx.hasUI || !isAlive || foreground) throw new Error("Memory queue needs one live interactive session.");
		const identity = memoryRequestIdentity(ctx);
		const current = new AbortController(); foreground = current; updateMembership();
		const combined = AbortSignal.any(signal ? [signal, current.signal] : [current.signal]);
		const epoch = generation;
		const isCurrent = () => {
			try { return isAlive && generation === epoch && !combined.aborted && JSON.stringify(memoryRequestIdentity(ctx)) === JSON.stringify(identity); }
			catch { return false; }
		};
		let activeConversation: AbortController | undefined;
		const abortConversation = () => activeConversation?.abort();
		combined.addEventListener("abort", abortConversation, { once: true });
		stopBackground();
		foregroundCompletion = (async () => {
			await backgroundCompletion; await conversationClose;
			combined.throwIfAborted();
			if (!isCurrent()) throw new Error("Memory request changed before ownership was acquired.");
			if (conversation?.client.signal?.aborted || conversation && conversation.identity.sessionID !== identity.sessionID) await closeConversation();
			if (operation === "cancel") { await closeConversation(); return { status: "cancelled", isSaved: false }; }
			const isPresentation = ["present", "manage", "confirm-reviewed"].includes(operation);
			if (isPresentation || operation === "reply" || operation === "amend") {
				if (operation === "amend") {
					const state = conversation;
					if (!state || state.owner !== owner || state.preview.isManagement) throw new Error("Amend the live queued finding through its original memory tool. Nothing was approved.");
					activeConversation = state.controller;
					if (params.revision !== undefined && params.revision !== state.preview.tuple.revision) throw new Error("The amendment does not match the live finding.");
					if (!takeConversationReply(state, ctx, identity.requestID)) return { status: "no-live-conversation-reply", tool: owner };
					await acknowledgeConversation(state, ctx);
					if (!isCurrent()) throw new Error("Memory request changed before amendment.");
					const amendment = queueObject(JSON.parse(JSON.stringify(params.amendment)));
					const frame = await state.client.request("amend", { ...state.preview.tuple, amendment });
					if (frame.type !== "presentation") { await closeConversation(); const { invocationID: _invocation, version: _version, ...publicResult } = frame; return publicResult; }
					if (!isCurrent()) throw new Error("Memory request changed before the amended presentation.");
					const preview = decodeQueuePreview(frame, state.identity);
					if (preview.isManagement || preview.tuple.claimID !== state.preview.tuple.claimID || preview.tuple.revision !== state.preview.tuple.revision || preview.tuple.sequence === state.preview.tuple.sequence || preview.digest === state.preview.digest) throw new Error("The amendment did not replace the exact live native display.");
					state.preview = preview;
					await showConversation(state, identity.requestID, true);
					return { status: "proposal-queued", isSaved: false, tool: owner };
				}
				const startType = operation === "present" ? "claim" : "manage-preview";
				const startFields = operation === "present" ? { revision: params.revision } : { mode: operation === "confirm-reviewed" ? "confirm-reviewed" : "crud", request: params.request };
				const isSame = conversation?.owner === owner && conversation.startType === startType && isDeepStrictEqual(conversation.startFields, startFields);
				if (operation === "reply" || operation === "manage" && isSame) {
					const state = conversation;
					if (!state || state.owner !== owner) throw new Error("Continue through the original memory tool, or cancel the pending proposal. Nothing was approved.");
					activeConversation = state.controller;
					const reply = takeConversationReply(state, ctx, identity.requestID);
					if (!reply) return { status: "no-live-conversation-reply", tool: owner };
					await acknowledgeConversation(state, ctx);
					if (!isCurrent()) throw new Error("Memory request changed before its reply.");
					const decisionID = randomUUID();
					let result: QueueObject;
					try {
						result = await state.client.request(state.preview.isManagement ? "manage-reply" : "reply", { ...state.preview.tuple, originalText: reply.text, submittedText: reply.text, decisionID, responseReference: identity.requestID }, true);
					} catch {
						await closeConversation();
						return { status: "outcome-unresolved", decisionID, recovery: state.preview.isManagement ? "manage-recover" : "recover" };
					}
					if (!isCurrent() || result.type === "blocked") {
						await closeConversation();
						return { status: "outcome-unresolved", decisionID, recovery: state.preview.isManagement ? "manage-recover" : "recover" };
					}
					if (result.type === "reply-clarify" && result.status === "no-decision") { await showConversation(state, identity.requestID, false); return { status: "needs-memory-clarification", tool: owner }; }
					if (state.preview.isManagement && result.type === "manage-cancelled" && result.status === "not-saved") { await closeConversation(); return { status: "not-saved" }; }
					let receipt: QueueObject;
					try {
						receipt = queueObject(result.receipt);
						if (result.type !== (state.preview.isManagement ? "manage-decision" : "decision") || receipt.decisionID !== decisionID || receipt.displayDigest !== state.preview.digest || !state.preview.isManagement && receipt.revision !== state.preview.tuple.revision || typeof receipt.status !== "string") throw new Error("Memory receipt identity changed.");
						if (receipt.status === "approved" && (typeof receipt.commit !== "string" || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(receipt.commit) || typeof receipt.auditRef !== "string" || !receipt.auditRef.startsWith("refs/"))) throw new Error("Approved memory receipt has no checked publication.");
					} catch {
						await closeConversation();
						return { status: "outcome-unresolved", decisionID, recovery: state.preview.isManagement ? "manage-recover" : "recover" };
					}
					if (receipt && receipt.status === "detached") {
						const next = await refreshConversation(state, identity.requestID);
						if (next.status !== "proposal-queued") await closeConversation();
						return { ...next, checkout: "prepared-not-saved", receipt };
					}
					await closeConversation();
					const { invocationID: _invocation, version: _version, ...publicResult } = result;
					return { ...publicResult, status: receipt.status };
				}
				if (isSame && conversation) { activeConversation = conversation.controller; await showConversation(conversation, identity.requestID, false); return { status: "proposal-queued", tool: owner }; }
				await closeConversation();
				const controller = new AbortController(); activeConversation = controller;
				const client = await deps.open(ctx.cwd, controller.signal);
				try {
					combined.throwIfAborted();
					const fields = queueObject(JSON.parse(JSON.stringify(startFields)));
					const frame = await client.request(startType, { ...fields, ...identity });
					if (frame.type !== (startType === "claim" ? "presentation" : "manage-presentation")) { const { invocationID: _invocation, version: _version, ...publicResult } = frame; await client.close(); return publicResult; }
					if (!isCurrent()) throw new Error("Memory request changed before presentation.");
					const state: MemoryConversationState = { client, controller, owner, identity, startType, startFields: fields, preview: decodeQueuePreview(frame, identity), proposalId: "", presentedForRequest: identity.requestID, isAcknowledged: false };
					conversation = state;
					await showConversation(state, identity.requestID, true);
					return { status: "proposal-queued", tool: owner };
				} catch (cause) { controller.abort(); if (conversation?.client === client) await closeConversation(); else await client.close(); throw cause; }
			}
			if (conversation && !["approved-list", "approved-get", "recover", "manage-recover"].includes(operation)) return { status: "proposal-awaits-reply", tool: conversation.owner };
			if (operation === "recover" || operation === "manage-recover") await closeConversation();
			const client = await deps.open(ctx.cwd, combined);
			try {
				const type = operation === "pending" ? "list" : operation;
				const fields = type === "list" ? { ...identity, offset: params.offset ?? "0" } : type === "approved-get" ? { request: params.request } : type === "recover" || type === "manage-recover" ? { decisionID: params.decisionID } : {};
				const result = await client.request(type, fields);
				if (type === "recover" || type === "manage-recover") {
					const receipt = result.receipt ? queueObject(result.receipt) : null;
					return { receipt, status: result.type === "blocked" || typeof receipt?.status !== "string" ? "outcome-unresolved" : receipt.status };
				}
				const { invocationID: _invocation, version: _version, ...publicResult } = result;
				return publicResult;
			} finally { await client.close(); }
		})();
		try { return await foregroundCompletion; }
		catch (cause) { if (activeConversation) await closeConversation(); throw cause; }
		finally {
			combined.removeEventListener("abort", abortConversation);
			if (conversation?.controller.signal.aborted) await closeConversation();
			if (foreground === current) foreground = undefined;
			updateMembership(); schedule();
		}
	}
	pi.on("context", async (event) => ({ messages: event.messages.filter((message) => message.role !== "custom" || message.customType !== "pi-core-memories:proposal") }));
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
	pi.on("input", (event, ctx) => {
		const previous = observedReply; observedReply = undefined;
		const state = conversation;
		if (!previous && state && event.source === "interactive" && !event.streamingBehavior && !event.images?.length && ctx.isIdle() && !ctx.hasPendingMessages() && Buffer.byteLength(event.text) <= 16_384) {
			const entry = conversationEntry(state, ctx);
			const leaf = ctx.sessionManager.getBranch().at(-1);
			if (entry && leaf) observedReply = { proposalId: state.proposalId, proposalEntryId: entry.id, previousLeafId: leaf.id, text: event.text, isRunStarted: false };
		}
		invalidate(false); failures = 0; isWorking = true; updateMembership();
	});
	pi.on("before_agent_start", (event) => {
		if (observedReply) {
			if (observedReply.isRunStarted || event.messageType !== "user" || event.prompt !== observedReply.text) observedReply = undefined;
			else observedReply.isRunStarted = true;
		}
		stopBackground(); isWorking = true; updateMembership();
	});
	pi.on("message_start", (event) => {
		if (event.message.role !== "user" || !observedReply) return;
		if (!observedReply.isRunStarted || observedReply.message || userText(event.message) !== observedReply.text) observedReply = undefined;
		else observedReply.message = event.message;
	});
	pi.on("agent_end", async (_event, ctx) => {
		context = ctx;
		if (conversation) {
			let requestID: string | undefined;
			try { requestID = memoryRequestIdentity(ctx).requestID; } catch {}
			if (requestID !== conversation.presentedForRequest) await closeConversation();
		}
		isWorking = false; updateMembership(); schedule();
	});
	pi.on("tool_call", async (event, ctx) => {
		if (!conversation || event.toolName === conversation.owner) return;
		let requestID: string | undefined;
		try { requestID = memoryRequestIdentity(ctx).requestID; } catch {}
		if (requestID !== conversation.presentedForRequest) await closeConversation();
		updateMembership();
	});
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
	const stop = async () => { isAlive = false; invalidate(); await leaveMembership(); await Promise.allSettled([backgroundCompletion, foregroundCompletion, conversationClose]); };
	pi.on("session_shutdown", stop);
	registerMemoryManagement(pi, (owner, request, signal, ctx) => perform(owner, "manage", { request }, signal, ctx));
	pi.registerTool({
		name: "memory_queue", label: "Memory queue", executionMode: "sequential",
		description: "Inspect pending findings, migration inventory and approved memories during ordinary conversation. Present only a relevant exact native proposal. Use reply after the user's later ordinary memory-specific response. The extension must match its observed interactive input to the exact durable user message after the complete proposal was appended; never supply approval text or a boolean in tool arguments. Queued, transformed, image-bearing or unmatched replies need a fresh ordinary response. Clarify ambiguous replies in chat. Use amend to replace wording in the live queued finding: preserve its source annotations and show the new exact native proposal. Amendment only prepares an unapproved draft; it needs a later approval. Cancel releases without saving. This tool opens no dialog or command workflow. Only a checked approved receipt proves a save; checkout preparation does not. Recovery checks an existing decision and never replays consent.",
		parameters: Type.Object({
			operation: Type.Union([Type.Literal("pending"), Type.Literal("inventory"), Type.Literal("approved-list"), Type.Literal("approved-get"), Type.Literal("present"), Type.Literal("amend"), Type.Literal("reply"), Type.Literal("cancel"), Type.Literal("confirm-reviewed"), Type.Literal("recover"), Type.Literal("manage-recover")]),
			revision: Type.Optional(Type.String({ pattern: "^[a-f0-9]{64}$", description: "Exact native finding revision from pending. Required by present; when supplied to amend, it must match the live finding." })),
			amendment: Type.Optional(Type.Object({
				replacement: Type.String({ minLength: 1, maxLength: 262144, description: "Complete replacement entry. Preserve every original source annotation. Native validation and transport limits apply." }),
				reason: Type.String({ minLength: 1, maxLength: 16384, description: "Reason for this unapproved wording change. This is not a user approval." }),
			}, { additionalProperties: false })),

			offset: Type.Optional(Type.String({ pattern: "^(0|[1-9][0-9]{0,9})$" })),
			request: Type.Optional(Type.Object({}, { additionalProperties: true, description: "Exact approved-memory get request: operation, base, path, locator and expected. Obtain exact fields from approved-list." })),
			decisionID: Type.Optional(Type.String({ pattern: "^[A-Za-z0-9._:-]{1,256}$" })),
		}, { additionalProperties: false }),
		async execute(_id, params, signal, _update, ctx) {
			const result = await perform("memory_queue", params.operation, params, signal, ctx);
			return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
		},
	});
	return stop;
}
