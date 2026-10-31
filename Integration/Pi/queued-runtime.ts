import { createHash, randomUUID } from "node:crypto";
import { rename, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { Type, type UserMessage } from "@earendil-works/pi-ai";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext, SessionEntry } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { callDreamModel, dreamBatchTextBytes, dreamRoots, escapeDreamDisplay, readDreamScope, runDreamWorker, type DreamReport, type DreamRequest, type DreamSelection, type DreamStart } from "./dream.ts";
import { decodeQueuePreview, openQueueClient, queueBytes, queueObject, visible, type QueueConnection, type QueueObject, type QueuePreview } from "./queue-client.ts";
import { registerMemoryManagement } from "./management.ts";
import { protectDreamSources } from "./source-protection.ts";
import { liveSessionIDs, markLiveSession, type LiveSessionMarker } from "./live-sessions.ts";

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
	startType: "claim" | "manage-preview" | "relocation-preview";
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
	reminderTimeoutMilliseconds: number;
	mark: typeof markLiveSession;
	live: typeof liveSessionIDs;
	liveDirectory: string;
};
export function registerQueuedRuntime(pi: ExtensionAPI, overrides: Partial<RuntimeDependencies> = {}): () => Promise<void> {
	const deps: RuntimeDependencies = { open: openQueueClient, run: runDreamWorker, roots: dreamRoots, scope: readDreamScope, call: callDreamModel, protect: protectDreamSources, idleMilliseconds: 30_000, reminderTimeoutMilliseconds: 2_000, mark: markLiveSession, live: liveSessionIDs, liveDirectory: join(homedir(), ".pi", "memory-host"), ...overrides };
	let context: ExtensionContext | undefined;
	let marker: LiveSessionMarker | undefined;
	let background: AbortController | undefined;
	let backgroundCompletion: Promise<void> | undefined;
	let foreground: AbortController | undefined;
	let foregroundCompletion: Promise<unknown> | undefined;
	let timer: ReturnType<typeof setTimeout> | undefined;
	let isAlive = false;
	let dreamStatus: string | undefined;
	let footerCounts = { queued: 0, review: 0, needsDecision: 0 };
	const noticed = new Set<string>();
	let timerDelay = 0;
	let marking: Promise<void> | undefined;
	const markerError = 'dreaming: error(code: liveSessionUnavailable, message: "Live session marker is unavailable")';
	let failures = 0;
	let interruptedCallSelection: DreamSelection | undefined;
	let generation = 0;
	let conversation: MemoryConversationState | undefined;
	let observedReply: MemoryReplyInput | undefined;
	let conversationClose = Promise.resolve();
	const answeredRevisions = new Set<string>();
	const pendingReminders: { anchor: number; message: Extract<AgentMessage, { role: "custom" }> }[] = [];
	let unanchoredReminder: { text: string | undefined; isReadFailed?: boolean } | undefined;
	for (const type of ["pi-core-memories:proposal", "pi-core-memories:needs-decision"]) pi.registerMessageRenderer(type, (message) => typeof message.content === "string" ? new Text(message.content, 0, 0) : undefined);
	function closeConversation(): Promise<void> {
		const previous = conversation; conversation = undefined; observedReply = undefined;
		if (previous) { previous.controller.abort(); conversationClose = previous.client.close(); }
		return conversationClose;
	}
	function reportDreamStatus(value: string | undefined): void {
		if (value !== undefined && !isAlive) return;
		dreamStatus = value;
		const counts = [footerCounts.queued ? `${footerCounts.queued} queued` : "", footerCounts.review ? `${footerCounts.review} to review` : "", footerCounts.needsDecision ? `${footerCounts.needsDecision} need decision` : ""].filter(Boolean);
		const text = value === undefined || value.startsWith("dreaming: error(") ? value : [value, ...counts].join(" · ");
		try { if (context?.hasUI) context.ui.setStatus("pi-core-memories:dream", text); } catch {}
	}
	async function drainDecisions(ctx: Pick<ExtensionContext, "cwd" | "sessionManager">, signal: AbortSignal): Promise<void> {
		const client = await deps.open(ctx.cwd, signal);
		try {
			const result = await client.request("drain", { sessionID: hash(ctx.sessionManager.getSessionId()) });
			if (result.type !== "drained" || typeof result.queued !== "number" || typeof result.review !== "number" || typeof result.needsDecision !== "number" || !Array.isArray(result.notices)) return;
			const revisions = result.notices.map((value) => queueObject(value).revision).filter((value): value is string => typeof value === "string" && !noticed.has(value));
			footerCounts = { queued: result.queued, review: result.review, needsDecision: result.needsDecision };
			for (const revision of revisions) {
				noticed.add(revision);
				pi.sendMessage({ customType: "pi-core-memories:needs-decision", content: `Your earlier memory decision for revision ${revision} was not applied and does not count: the proposal, its evidence or the memory store changed first. Nothing was saved. The agent will present the current proposal for a new answer.`, display: true, details: { revision } }, { triggerTurn: false });
			}
		} finally { await client.close(); reportDreamStatus(dreamStatus); }
	}
	async function recordBlockedDream(invocationID: string, report: DreamReport): Promise<void> {
		const path = join(deps.liveDirectory, "last-dream-blocked.json");
		const staging = `${path}.${process.pid}-${randomUUID()}.tmp`;
		try {
			await writeFile(staging, JSON.stringify({ time: new Date().toISOString(), invocationID, status: report.status, reason: report.reason, detail: report.detail }) + "\n", { mode: 0o600, flag: "wx" });
			await rename(staging, path);
		} catch { await unlink(staging).catch(() => {}); }
	}
	function stopBackground(): void {
		clearTimeout(timer); timer = undefined; background?.abort();
		if (dreamStatus === "dreaming: active") reportDreamStatus("dreaming: idle");
	}
	function retryMark(): void {
		const ctx = context;
		if (marking || marker || !ctx || !ctx.sessionManager.getSessionFile()) return;
		const epoch = generation;
		marking = (async () => {
			await new Promise((resolve) => { const wait = setTimeout(resolve, deps.idleMilliseconds); wait.unref?.(); });
			if (generation !== epoch || marker || context !== ctx) return;
			try {
				const created = await deps.mark(deps.liveDirectory, ctx.sessionManager.getSessionId());
				if (generation !== epoch || marker) { await created.close(); return; }
				marker = created;
			} catch {}
		})().finally(() => { marking = undefined; if (generation === epoch) schedule(); });
	}
	function invalidateConversation(): void { foreground?.abort(); generation++; void closeConversation(); }
	function invalidate(): void { invalidateConversation(); stopBackground(); interruptedCallSelection = undefined; }
	async function leaveSession(): Promise<void> {
		const previous = marker; marker = undefined;
		reportDreamStatus(undefined);
		await previous?.close();
	}
	function schedule(): void {
		const isMarkerMissing = !marker && !!context?.sessionManager.getSessionFile();
		const isBlocked = !isAlive || !context || isMarkerMissing || !!foreground || !!conversation || failures >= 3;
		if (isBlocked) { clearTimeout(timer); timer = undefined; }
		if (!isAlive || !context) return;
		if (isMarkerMissing) { reportDreamStatus(markerError); retryMark(); return; }
		if (isBlocked) {
			if ((foreground || conversation) && !dreamStatus?.startsWith("dreaming: error(")) reportDreamStatus("dreaming: paused");
			return;
		}
		if (background) return;
		if (!dreamStatus?.startsWith("dreaming: error(")) reportDreamStatus("dreaming: idle");
		const delay = deps.idleMilliseconds * 2 ** failures;
		if (timer && timerDelay <= delay) return;
		clearTimeout(timer); timerDelay = delay;
		timer = setTimeout(() => { timer = undefined; void startBackground(); }, delay);
		timer.unref?.();
	}
	async function startBackground(): Promise<void> {
		const ctx = context;
		if (!ctx || !isAlive || foreground || conversation || background) { schedule(); return; }
		const model = ctx.model;
		if (!model || !["openai", "openai-codex", "anthropic"].includes(model.provider)) {
			reportDreamStatus('dreaming: error(code: unsupportedProvider, message: "Selected provider cannot run dreaming")'); return;
		}
		const batchTextBytes = dreamBatchTextBytes(model.contextWindow);
		if (batchTextBytes === null) {
			reportDreamStatus('dreaming: error(code: contextWindow, message: "Selected context window cannot run dreaming")'); return;
		}
		const selection: DreamSelection = { provider: model.provider, modelID: model.id, thinkingLevel: ctx.thinkingLevel ?? pi.getThinkingLevel() };
		const current = new AbortController(); background = current;
		const isCurrent = () => isAlive && !current.signal.aborted && background === current;
		const sessionID = ctx.sessionManager.getSessionId();
		let isLiveUnavailable = false;
		const liveSessions = async () => {
			try { return [...new Set([sessionID, ...await deps.live(deps.liveDirectory)])].sort(); }
			catch (error) { isLiveUnavailable = true; throw error; }
		};
		backgroundCompletion = (async () => {
			try {
				await conversationClose;
				current.signal.throwIfAborted();
				if (isCurrent()) reportDreamStatus("dreaming: applying");
				await drainDecisions(ctx, current.signal).catch(() => {});
				current.signal.throwIfAborted();
				if (isCurrent()) reportDreamStatus("dreaming: active");
				const excludedSessionIDs = await liveSessions();
				const roots = await deps.roots(getAgentDir(), ctx.cwd);
				const scope = await deps.scope(current.signal);
				current.signal.throwIfAborted();
				const invocationID = randomUUID();
				const resume = isDeepStrictEqual(interruptedCallSelection, selection) ? "retryInterruptedCall" : "inspectOrContinue";
				interruptedCallSelection = undefined;
				const start: DreamStart & { excludedSessionIDs: string[] } = { version: 1, type: "start", invocationID, roots, selection, resume, batchTextBytes, ...scope, excludedSessionIDs };
				const report = await deps.run(start, async (request, signal) => {
					if (!isAlive || current.signal.aborted || ctx.sessionManager.getSessionId() !== sessionID || ctx.model?.id !== model.id || ctx.model?.provider !== model.provider || (ctx.thinkingLevel ?? pi.getThinkingLevel()) !== selection.thinkingLevel) throw new Error("Memory worker selection or lifecycle changed.");
					assertArchivedRequest(request, await liveSessions());
					if (signal.aborted || current.signal.aborted) throw new Error("Memory worker was cancelled.");
					if (isCurrent()) reportDreamStatus("dreaming: active");
					try { return await deps.call(request, ctx, model, selection, signal); }
					catch (error) {
						if (isCurrent() && !signal.aborted) reportDreamStatus('dreaming: error(code: backendFailure, message: "Dream model invocation failed")');
						throw error;
					}
				}, current.signal, () => {}, (value: unknown, signal: AbortSignal) => deps.protect(pi, invocationID, value, signal));
				if (!isCurrent()) return;
				await drainDecisions(ctx, current.signal).catch(() => {});
				if (!isCurrent()) return;
				const recorded = report.callSelection;
				const isRetrying = report.status === "pending" && report.reason === "interruptedCall" && (!recorded || isDeepStrictEqual(recorded, selection));
				if (isRetrying) interruptedCallSelection = selection;
				const isRescheduled = report.status !== "blocked" && (report.status !== "pending" || isRetrying || report.reason === "cancelled");
				failures = isRescheduled ? 0 : 3;
				const blockedReason = report.reason && /^[A-Za-z0-9:._-]{1,80}$/.test(report.reason) ? report.reason : "unknown";
				reportDreamStatus(isRescheduled ? "dreaming: idle"
					: report.status === "blocked" ? `dreaming: error(code: blocked, reason: ${blockedReason}, message: "Native dream worker blocked the run")`
					: report.reason === "interruptedCall" && recorded ? `dreaming: error(code: interruptedCall, message: ${JSON.stringify(escapeDreamDisplay(`Interrupted dream needs the model it started with: ${recorded.provider}/${recorded.modelID}, thinking ${recorded.thinkingLevel}`))})`
					: `dreaming: error(code: pending, reason: ${blockedReason}, message: "Native dream worker kept the run pending")`);
				if (report.status === "blocked") await recordBlockedDream(invocationID, report);
			} catch {
				if (isCurrent() && isLiveUnavailable) reportDreamStatus(markerError);
				else if (isCurrent()) {
					failures++;
					if (!dreamStatus?.startsWith("dreaming: error(")) reportDreamStatus('dreaming: error(code: workerFailure, message: "Background dream run failed")');
				}
			}
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
		const type = state.preview.isRelocation ? "relocation-presented" : state.preview.isManagement ? "manage-presented" : "presented";
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
		if (frame.type !== (state.startType === "claim" ? "presentation" : state.startType === "relocation-preview" ? "relocation-presentation" : "manage-presentation")) {
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
		const current = new AbortController(); foreground = current;
		const combined = AbortSignal.any(signal ? [signal, current.signal] : [current.signal]);
		const epoch = generation;
		const isCurrent = () => {
			try { return isAlive && generation === epoch && !combined.aborted && JSON.stringify(memoryRequestIdentity(ctx)) === JSON.stringify(identity); }
			catch { return false; }
		};
		let activeConversation: AbortController | undefined;
		const abortConversation = () => activeConversation?.abort();
		combined.addEventListener("abort", abortConversation, { once: true });
		clearTimeout(timer); timer = undefined;
		const refreshCounts = () => conversation || background ? Promise.resolve() : drainDecisions(ctx, combined).catch(() => {});
		foregroundCompletion = (async () => {
			await conversationClose;
			if (operation !== "reply") await refreshCounts();
			const result = await run();
			if (isCurrent()) await refreshCounts();
			return result;
		})();
		async function run(): Promise<unknown> {
			combined.throwIfAborted();
			if (!isCurrent()) throw new Error("Memory request changed before ownership was acquired.");
			if (conversation?.client.signal?.aborted || conversation && conversation.identity.sessionID !== identity.sessionID) await closeConversation();
			if (operation === "cancel") { await closeConversation(); return { status: "cancelled", isSaved: false }; }
			const isPresentation = ["present", "manage", "confirm-reviewed", "relocate-snippets"].includes(operation);
			if (isPresentation || operation === "reply" || operation === "amend") {
				if (operation === "amend") {
					const state = conversation;
					if (!state || state.owner !== owner || state.preview.isManagement || state.preview.isRelocation) throw new Error("Amend the live queued finding through its original memory tool. Nothing was approved.");
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
					if (preview.isManagement || preview.isRelocation || preview.tuple.claimID !== state.preview.tuple.claimID || preview.tuple.revision !== state.preview.tuple.revision || preview.tuple.sequence === state.preview.tuple.sequence || preview.digest === state.preview.digest) throw new Error("The amendment did not replace the exact live native display.");
					state.preview = preview;
					answeredRevisions.add(preview.tuple.revision);
					await showConversation(state, identity.requestID, true);
					return { status: "proposal-queued", isSaved: false, tool: owner };
				}
				const startType = operation === "present" ? "claim" : operation === "relocate-snippets" ? "relocation-preview" : "manage-preview";
				const startFields = operation === "present" ? { revision: params.revision } : operation === "relocate-snippets" ? { baselineRunID: params.baselineRunID, replacement: params.replacement } : { mode: operation === "confirm-reviewed" ? "confirm-reviewed" : "crud", request: params.request };
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
					const recovery = state.preview.isRelocation ? "relocation-recover" : state.preview.isManagement ? "manage-recover" : "recover";
					let result: QueueObject;
					try {
						result = await state.client.request(state.preview.isRelocation ? "relocation-reply" : state.preview.isManagement ? "manage-reply" : "reply", { ...state.preview.tuple, originalText: reply.text, submittedText: reply.text, decisionID, responseReference: identity.requestID }, true);
					} catch {
						await closeConversation();
						return { status: "outcome-unresolved", decisionID, recovery };
					}
					if (!isCurrent() || result.type === "blocked") {
						await closeConversation();
						return { status: "outcome-unresolved", decisionID, recovery };
					}
					if (result.type === "reply-clarify" && result.status === "no-decision") { await showConversation(state, identity.requestID, false); return { status: "needs-memory-clarification", tool: owner }; }
					if ((state.preview.isManagement && result.type === "manage-cancelled" || state.preview.isRelocation && result.type === "relocation-cancelled") && result.status === "not-saved") { await closeConversation(); return { status: "not-saved" }; }
					let receipt: QueueObject;
					try {
						receipt = queueObject(result.receipt);
						if (result.type !== (state.preview.isRelocation ? "relocation-decision" : state.preview.isManagement ? "manage-decision" : "decision") || receipt.decisionID !== decisionID || receipt.displayDigest !== state.preview.digest || !state.preview.isManagement && !state.preview.isRelocation && receipt.revision !== state.preview.tuple.revision || typeof receipt.status !== "string" || state.preview.isRelocation && receipt.status !== "relocated") throw new Error("Memory receipt identity changed.");
						if (state.preview.isRelocation && (receipt.sessionID !== state.identity.sessionID || receipt.requestID !== state.identity.requestID || receipt.responseReference !== identity.requestID)) throw new Error("Relocation receipt request changed.");
						if (receipt.status === "approved" && (typeof receipt.commit !== "string" || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(receipt.commit) || typeof receipt.auditRef !== "string" || !receipt.auditRef.startsWith("refs/"))) throw new Error("Approved memory receipt has no checked publication.");
					} catch {
						await closeConversation();
						return { status: "outcome-unresolved", decisionID, recovery };
					}
					if (state.startType === "claim" && receipt.status !== "detached") answeredRevisions.add(state.preview.tuple.revision);
					if (receipt.status === "queued") {
						await closeConversation();
						footerCounts = { ...footerCounts, queued: footerCounts.queued + 1, review: Math.max(0, footerCounts.review - 1) };
						reportDreamStatus(dreamStatus);
						return { status: "decision-queued", decisionID, recovery, message: "Your decision was recorded. A dream run holds the memory lock, so the decision will be applied shortly, after the same native checks. Nothing is saved yet." };
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
					if (frame.type !== (startType === "claim" ? "presentation" : startType === "relocation-preview" ? "relocation-presentation" : "manage-presentation")) { const { invocationID: _invocation, version: _version, ...publicResult } = frame; await client.close(); return publicResult; }
					if (!isCurrent()) throw new Error("Memory request changed before presentation.");
					const state: MemoryConversationState = { client, controller, owner, identity, startType, startFields: fields, preview: decodeQueuePreview(frame, identity), proposalId: "", presentedForRequest: identity.requestID, isAcknowledged: false };
					conversation = state;
					await showConversation(state, identity.requestID, true);
					return { status: "proposal-queued", tool: owner };
				} catch (cause) { controller.abort(); if (conversation?.client === client) await closeConversation(); else await client.close(); throw cause; }
			}
			if (conversation && !["approved-list", "approved-get", "recover", "manage-recover", "relocation-recover"].includes(operation)) return { status: "proposal-awaits-reply", tool: conversation.owner };
			if (operation === "recover" || operation === "manage-recover" || operation === "relocation-recover") await closeConversation();
			const client = await deps.open(ctx.cwd, combined);
			try {
				const type = operation === "pending" ? "list" : operation;
				const fields = type === "list" ? { ...identity, offset: params.offset ?? "0" } : type === "approved-get" ? { request: params.request } : type === "recover" || type === "manage-recover" || type === "relocation-recover" ? { decisionID: params.decisionID } : {};
				const result = await client.request(type, fields);
				if (type === "recover" || type === "manage-recover" || type === "relocation-recover") {
					const receipt = result.receipt ? queueObject(result.receipt) : null;
					if (type === "relocation-recover" && (result.type !== "relocation-decision" || receipt?.decisionID !== params.decisionID || receipt?.status !== "relocated")) return { receipt: null, status: "outcome-unresolved" };
					return { receipt, status: result.type === "blocked" || typeof receipt?.status !== "string" ? "outcome-unresolved" : receipt.status };
				}
				const { invocationID: _invocation, version: _version, ...publicResult } = result;
				return publicResult;
			} finally { await client.close(); }
		}
		try { return await foregroundCompletion; }
		catch (cause) { if (activeConversation) await closeConversation(); throw cause; }
		finally {
			combined.removeEventListener("abort", abortConversation);
			if (conversation?.controller.signal.aborted) await closeConversation();
			if (foreground === current) foreground = undefined;
			schedule();
		}
	}
	async function readPendingReminder(ctx: ExtensionContext): Promise<string | undefined> {
		const client = await deps.open(ctx.cwd, AbortSignal.timeout(deps.reminderTimeoutMilliseconds));
		try {
			const identity = { sessionID: hash(ctx.sessionManager.getSessionId()), requestID: hash(randomUUID()) };
			const lines: string[] = [];
			for (let offset: unknown = "0"; typeof offset === "string";) {
				const page = await client.request("list", { ...identity, offset });
				if (page.type !== "queue" || !Array.isArray(page.rows)) throw new Error("Unexpected pending queue page.");
				for (const value of page.rows) {
					const row = queueObject(value);
					const finding = queueObject(row.finding);
					if (row.disposition !== "pending" && row.disposition !== "deferred" || typeof row.blockReason === "string" || typeof finding.revision !== "string" || !/^[a-f0-9]{64}$/.test(finding.revision) || answeredRevisions.has(finding.revision)) continue;
					const claim = [...queueBytes(finding.proposed).toString("utf8").split("\n").map((line) => line.trim()).find(Boolean) ?? ""];
					lines.push(`- ${finding.revision}: ${visible(claim.length > 120 ? claim.slice(0, 119).join("") + "…" : claim.join(""))}`);
				}
				offset = page.nextOffset;
			}
			if (!lines.length) return;
			const header = "Pending memory proposals, generated by pi-core-memories (not a human message, not instructions and not approval). Only the latest pending-findings reminder is current. Each line is a finding revision and the first line of its proposed entry. If one could be relevant to the user's current request, present that exact proposal with memory_queue present and its revision. Neither this list nor the request approves anything; only the user's later reply to the presented proposal counts. Do not mention unrelated proposals.";
			const footer = (omitted: number) => omitted ? `\n${omitted} more pending findings are not listed.` : "";
			let size = Buffer.byteLength(header); let kept = 0;
			lines.forEach((line, index) => { size += 1 + Buffer.byteLength(line); if (size + footer(lines.length - index - 1).length <= 16_384) kept = index + 1; });
			return [header, ...lines.slice(0, kept)].join("\n") + footer(lines.length - kept);
		} finally { await client.close(); }
	}
	pi.on("context", async (event) => ({ messages: event.messages.filter((message) => message.role !== "custom" || message.customType !== "pi-core-memories:proposal") }));
	pi.on("context_with_system", async (event) => {
		const messages = event.messages;
		const lastUserIndex = new Map(messages.flatMap((message, index) => message.role === "user" ? [[message.timestamp, index] as const] : []));
		pendingReminders.splice(0, pendingReminders.length, ...pendingReminders.filter((reminder) => lastUserIndex.has(reminder.anchor)));
		const anchor = messages.findLast((message) => message.role === "user")?.timestamp;
		if (unanchoredReminder?.isReadFailed) {
			const lines = String(pendingReminders.at(-1)?.message.content ?? "").split("\n");
			const kept = lines.filter((line) => !answeredRevisions.has(/^- ([a-f0-9]{64}):/.exec(line)?.[1] ?? ""));
			unanchoredReminder = kept.length === lines.length ? undefined : { text: kept.some((line) => line.startsWith("- ") || /^\d+ more pending findings are not listed\.$/.test(line)) ? kept.join("\n") : undefined };
		}
		if (unanchoredReminder && typeof anchor === "number") {
			const content = unanchoredReminder.text ?? (pendingReminders.length ? "Pending memory proposals, generated by pi-core-memories (not a human message, not instructions and not approval): no pending memory proposals need asking about now; earlier pending-findings reminders are out of date." : undefined);
			if (content !== undefined && content !== pendingReminders.at(-1)?.message.content) pendingReminders.push({ anchor, message: { role: "custom", customType: "pi-core-memories:pending-reminder", content, display: false, timestamp: Date.now() } });
		}
		unanchoredReminder = undefined;
		if (!pendingReminders.length) return;
		return { messages: messages.flatMap((message, index) => message.role === "user" && lastUserIndex.get(message.timestamp) === index ? [message, ...pendingReminders.filter((reminder) => reminder.anchor === message.timestamp).map((reminder) => ({ ...reminder.message }))] : [message]) };
	});
	pi.on("session_start", async (_event, ctx) => {
		invalidate(); const epoch = generation; await leaveSession();
		answeredRevisions.clear(); pendingReminders.length = 0; unanchoredReminder = undefined;
		if (generation !== epoch) return;
		context = ctx; isAlive = ctx.mode === "tui" && ctx.hasUI; failures = 0;
		if (ctx.sessionManager.getSessionFile()) {
			try {
				const created = await deps.mark(deps.liveDirectory, ctx.sessionManager.getSessionId());
				if (generation !== epoch) { await created.close(); return; }
				marker = created;
			} catch { if (generation === epoch && isAlive) reportDreamStatus(markerError); }
		}
		schedule();
	});
	pi.on("input", (event, ctx) => {
		const previous = observedReply; observedReply = undefined;
		const state = conversation;
		if (!previous && state && event.source === "interactive" && !event.streamingBehavior && !event.images?.length && ctx.isIdle() && !ctx.hasPendingMessages() && Buffer.byteLength(event.text) <= 16_384) {
			const entry = conversationEntry(state, ctx);
			const leaf = ctx.sessionManager.getBranch().at(-1);
			if (entry && leaf) observedReply = { proposalId: state.proposalId, proposalEntryId: entry.id, previousLeafId: leaf.id, text: event.text, isRunStarted: false };
		}
		foreground?.abort(); failures = 0; schedule();
	});
	pi.on("before_agent_start", async (event, ctx) => {
		if (observedReply) {
			if (observedReply.isRunStarted || event.messageType !== "user" || event.prompt !== observedReply.text) observedReply = undefined;
			else observedReply.isRunStarted = true;
		}
		unanchoredReminder = undefined;
		if (!isAlive || event.messageType !== "user" || conversation) return;
		try { unanchoredReminder = { text: await readPendingReminder(ctx) }; } catch { unanchoredReminder = { text: undefined, isReadFailed: true }; }
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
		schedule();
	});
	pi.on("tool_call", async (event, ctx) => {
		if (!conversation || event.toolName === conversation.owner) return;
		let requestID: string | undefined;
		try { requestID = memoryRequestIdentity(ctx).requestID; } catch {}
		if (requestID !== conversation.presentedForRequest) await closeConversation();
		schedule();
	});
	pi.on("model_select", (_event, ctx) => { invalidate(); context = ctx; failures = 0; reportDreamStatus("dreaming: idle"); schedule(); });
	pi.on("thinking_level_select", (_event, ctx) => { invalidate(); context = ctx; failures = 0; reportDreamStatus("dreaming: idle"); schedule(); });
	pi.on("session_before_switch", async () => { isAlive = false; invalidate(); await leaveSession(); });
	pi.on("session_before_fork", async () => { isAlive = false; invalidate(); await leaveSession(); });
	pi.on("session_before_tree", invalidateConversation);
	pi.on("session_before_compact", invalidateConversation);
	pi.on("session_tree", (_event, ctx) => { context = ctx; schedule(); });
	pi.on("session_compact", (_event, ctx) => { context = ctx; schedule(); });
	pi.on("session_compact_failed", (_event, ctx) => { context = ctx; schedule(); });
	const stop = async () => { isAlive = false; invalidate(); await leaveSession(); await Promise.allSettled([backgroundCompletion, foregroundCompletion, conversationClose]); };
	pi.on("session_shutdown", stop);
	registerMemoryManagement(pi, (owner, request, signal, ctx) => perform(owner, "manage", { request }, signal, ctx));
	pi.registerTool({
		name: "memory_queue", label: "Memory queue", executionMode: "sequential",
		description: "Inspect pending findings, migration inventory and approved memories during ordinary conversation. Present only a relevant exact native proposal. Use reply after the user's later ordinary memory-specific response. The extension must match its observed interactive input to the exact durable user message after the complete proposal was appended; never supply approval text or a boolean in tool arguments. Queued, transformed, image-bearing or unmatched replies need a fresh ordinary response. Clarify ambiguous replies in chat. Use amend to replace wording in the live queued finding: preserve its source annotations and show the new exact native proposal. Amendment only prepares an unapproved draft; it needs a later approval. Cancel releases without saving. This tool opens no dialog or command workflow. Only a checked approved receipt proves a save; checkout preparation does not. Recovery checks an existing decision and never replays consent. relocate-snippets previews only an authenticated exact original snippet inventory from a named authoritative capture at a canonical replacement directory. Never guess replacement evidence. It requires a later explicit snippet-relocation approval, not memory approval; reply uses the same original-user boundary. A relocated receipt changes only future source intake, not memories or history.",
		parameters: Type.Object({
			operation: Type.Union([Type.Literal("pending"), Type.Literal("inventory"), Type.Literal("approved-list"), Type.Literal("approved-get"), Type.Literal("present"), Type.Literal("amend"), Type.Literal("reply"), Type.Literal("cancel"), Type.Literal("confirm-reviewed"), Type.Literal("recover"), Type.Literal("manage-recover"), Type.Literal("relocate-snippets"), Type.Literal("relocation-recover")]),
			baselineRunID: Type.Optional(Type.String({ maxLength: 256, description: "Authoritative admitted run with a complete exact original snippet inventory. Required for relocate-snippets." })),
			replacement: Type.Optional(Type.String({ maxLength: 4096, description: "Exact canonical replacement snippet directory with authenticated original contents. Required for relocate-snippets. This is not permission to create or populate it." })),
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
