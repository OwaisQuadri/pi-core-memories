import { execFile, spawn } from "node:child_process";
import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { AssistantMessage, Context } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { type Component, Text, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { commandPath, commandReady } from "./command.ts";
import { SOURCE_PROTECTION_INPUT_BYTES, SOURCE_PROTECTION_REPLY_BYTES, type SourceProtectionResult } from "./source-protection.ts";

export const DREAM_REVIEW_TYPE = "core-memory-dream-review";
export const MAXIMUM_FRAME_BYTES = 32 * 1_048_576 * 6 + 65_536;
const maximumTextBytes = 262_144;
const maximumReplyBytes = maximumTextBytes * 6 + 8192;
const maximumAggregateBytes = MAXIMUM_FRAME_BYTES * 2 + SOURCE_PROTECTION_INPUT_BYTES * 16 + 18;

type ObjectValue = Record<string, unknown>;
export type DreamSelection = { provider: string; modelID: string; thinkingLevel: string };
export type DreamRoots = { state: string; sessions: string; memory: string; snippets: string | null; prompts: string | null; globalAgents: string | null };
export type DreamScopeOptions = { deviceKey?: string; projectBindings?: Record<string, string> };
export type DreamStart = { version: 1; type: "start"; invocationID: string; roots: DreamRoots; selection: DreamSelection; resume: "inspectOrContinue" | "retryInterruptedCall" | "replaceInvalidResponse"; batchTextBytes: number; excludedSessionIDs?: string[] } & DreamScopeOptions;
export type DreamRequest = { version: 1; type: "modelRequest"; invocationID: string; requestID: string; runID: string; generation: string; inputHash: string; contextHash: string; requestHash: string; selection: DreamSelection; systemPrompt: string; messages: { role: "system" | "user"; text: string; timestampMilliseconds: number }[] };
type DreamSource = { sessionID: string; entryID: string; partIndex: number };
type DreamProposal = { ref: string; commit: string; base: string; path: string; sources: DreamSource[]; contradictions: string };
type DreamNote = { kind: string; sources: DreamSource[]; explanation: string; reasonCode: string | null; ownerReference: string | null; contradictions: string };
export type DreamReport = { version: 1; type: "final"; invocationID: string; status: "completed" | "pending" | "noNewRecords" | "busy" | "blocked"; generation: string; runID: string | null; base: string | null; proposals: DreamProposal[]; notes: DreamNote[]; isBacklog: boolean; isRecovered: boolean; reason: string | null; detail: string | null; unfinishedTails: number; callSelection?: DreamSelection };
export type DreamCoverage = { backlogBytes: number | null; backlogLimitBytes: number | null; undreamtBytes: number | null; nextBytes: number | null; plannedBytes: number; completedBytes: number; repeatedRecords: number; estimateSeconds: number | null };
function coverageFields(result: ObjectValue): DreamCoverage {
	const nullable = (value: unknown) => value === null ? null : integer(value);
	const coverage = { backlogBytes: nullable(result.backlogBytes), backlogLimitBytes: nullable(result.backlogLimitBytes), undreamtBytes: nullable(result.undreamtBytes), nextBytes: nullable(result.nextBytes), plannedBytes: integer(result.plannedBytes), completedBytes: integer(result.completedBytes), repeatedRecords: integer(result.repeatedRecords, 1000), estimateSeconds: result.estimateSeconds === null ? null : result.estimateSeconds as number };
	if (coverage.completedBytes > coverage.plannedBytes || (coverage.undreamtBytes === null) !== (coverage.nextBytes === null)) failure();
	if (coverage.undreamtBytes !== null && (coverage.plannedBytes > coverage.undreamtBytes || coverage.nextBytes! > coverage.undreamtBytes - coverage.plannedBytes)) failure();
	if (coverage.estimateSeconds !== null && (typeof coverage.estimateSeconds !== "number" || !Number.isFinite(coverage.estimateSeconds) || coverage.estimateSeconds <= 0)) failure();
	return coverage;
}
export function dreamCoverage(value: unknown, start: DreamStart): DreamCoverage {
	const result = header(value, start);
	fields(result, ["version", "type", "invocationID", "backlogBytes", "backlogLimitBytes", "undreamtBytes", "nextBytes", "plannedBytes", "completedBytes", "repeatedRecords", "estimateSeconds"]);
	if (result.type !== "progress") failure();
	const coverage = coverageFields(result);
	if ((coverage.backlogBytes === null) !== (coverage.undreamtBytes === null) || (coverage.backlogBytes === null) !== (coverage.backlogLimitBytes === null)) failure();
	if (coverage.backlogBytes !== null && coverage.undreamtBytes! > coverage.backlogBytes) failure();
	return coverage;
}
const legacyCoverageFields = ["plannedBytes", "completedBytes", "undreamtBytes", "nextBytes", "repeatedRecords", "estimateSeconds", "archiveBytes", "processedBytes", "backlogBytes", "backlogLimitBytes"];
function savedDreamCoverage(value: unknown, start: DreamStart): DreamCoverage {
	const result = object(value);
	if (!("archiveBytes" in result) && "backlogBytes" in result) return dreamCoverage({ ...result, version: 1, type: "progress", invocationID: start.invocationID }, start);
	if (Object.keys(result).some((key) => !legacyCoverageFields.includes(key))) failure();
	return coverageFields({ ...result, backlogBytes: null, backlogLimitBytes: null });
}
type Paint = (color: "dim" | "muted" | "accent", text: string) => string;
export function dreamBacklogBar(coverage: DreamCoverage, width: number, paint: Paint = (_color, text) => text): string {
	const backlog = coverage.backlogBytes!;
	const left = coverage.undreamtBytes! - coverage.completedBytes;
	const total = Math.max(coverage.backlogLimitBytes!, left) + backlog - left;
	const cells = (bytes: number) => total === 0 ? 0 : Math.round(width * bytes / total);
	const used = cells(backlog);
	const dreamt = cells(backlog - left);
	return paint("dim", "░".repeat(width - used)) + paint("muted", "▒".repeat(used - dreamt)) + paint("accent", "█".repeat(dreamt));
}
export function dreamProgressText(coverage: DreamCoverage | undefined, elapsedSeconds: number | undefined, phase: string, width = 40, paint?: Paint): string {
	const elapsed = elapsedSeconds === undefined ? "unknown" : `${Math.floor(elapsedSeconds)}s`;
	const title = `Dream · ${phase} · elapsed ${elapsed}`;
	if (!coverage) return title;
	const lines = [title];
	if (coverage.backlogBytes !== null) {
		const left = coverage.undreamtBytes! - coverage.completedBytes;
		const free = Math.max(0, coverage.backlogLimitBytes! - left);
		lines.push(dreamBacklogBar(coverage, width, paint));
		lines.push(`░ free ${megabytes(free)} · ▒ not dreamt ${megabytes(left)} · █ dreamt ${megabytes(coverage.backlogBytes - left)} · cap ${megabytes(coverage.backlogLimitBytes!)} undreamt · last 7 days`);
	} else lines.push("Backlog unknown for this saved batch");
	const estimate = coverage.estimateSeconds === null ? "unknown" : `~${Math.ceil(coverage.estimateSeconds)}s`;
	const repeated = coverage.repeatedRecords ? ` · retry repeats ${coverage.repeatedRecords} records` : "";
	lines.push(`This batch ${megabytes(coverage.plannedBytes)} · next batch ${coverage.nextBytes === null ? "unknown" : megabytes(coverage.nextBytes)} · estimate ${estimate}${repeated}`);
	return lines.join("\n");
}
function megabytes(bytes: number): string { return `${(bytes / 1_048_576).toFixed(1)} MB`; }
function progressComponent(lines: (width: number) => string): Component {
	return { render: (width) => lines(width).split("\n").flatMap((line) => wrapTextWithAnsi(line, width)), invalidate: () => {} };
}
export function dreamBatchTextBytes(contextWindow: unknown): number | null {
	if (typeof contextWindow !== "number" || !Number.isSafeInteger(contextWindow) || contextWindow < 65_536) return null;
	return Math.min(contextWindow, 1_048_576);
}
export type DreamCall = (request: DreamRequest, signal: AbortSignal) => Promise<string>;
export type DreamSourceProtectionCall = (request: unknown, signal: AbortSignal) => Promise<SourceProtectionResult>;

function failure(): never {
	const frames = (new Error().stack ?? "").split("\n").slice(2, 4).map((frame) => frame.trim().replace(/\(.*\//, "("));
	throw new Error(`Dream check failed ${frames.join(" ") || "at unknown location"}`);
}
function message(error: unknown): string {
	return Buffer.from(error instanceof Error ? error.message : String(error)).subarray(0, 1000).toString();
}
function object(value: unknown): ObjectValue {
	if (!value || typeof value !== "object" || Array.isArray(value)) return failure();
	return value as ObjectValue;
}
function fields(value: ObjectValue, names: string[]): void {
	if (Object.keys(value).sort().join("\0") !== [...names].sort().join("\0")) failure();
}
function isWellFormedText(value: string): boolean { return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(value); }
function text(value: unknown, maximum = 4096): string {
	if (typeof value !== "string" || !isWellFormedText(value) || Buffer.byteLength(value) > maximum || value.includes("\0")) return failure();
	return value;
}
function nullableText(value: unknown, maximum = 4096): string | null { return value === null ? null : text(value, maximum); }
function identifier(value: unknown): string {
	const result = text(value, 256);
	if (!/^[A-Za-z0-9_.:-]+$/.test(result)) failure();
	return result;
}
function hash(value: unknown): string {
	const result = text(value, 64);
	if (!/^[a-f0-9]{64}$/.test(result)) failure();
	return result;
}
function commit(value: unknown): string {
	const result = text(value, 64);
	if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(result)) failure();
	return result;
}
function generation(value: unknown): string {
	const result = text(value, 20);
	if (!/^(?:0|[1-9][0-9]*)$/.test(result) || BigInt(result) > 18446744073709551615n) failure();
	return result;
}
function integer(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > maximum) return failure();
	return value;
}
function list(value: unknown, maximum: number): unknown[] {
	if (!Array.isArray(value) || value.length > maximum) return failure();
	return value;
}
function isBoolean(value: unknown): boolean {
	if (typeof value !== "boolean") return failure();
	return value;
}

export function parseDreamJSON(bytes: Uint8Array): unknown {
	const source = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
	let index = 0;
	function space(): void { while (/[\t\r\n ]/.test(source[index] ?? "x")) index++; }
	function string(): string {
		space();
		const start = index;
		if (source[index++] !== '"') return failure();
		while (index < source.length) {
			const character = source[index++];
			if (character === "\\") index++;
			else if (character === '"') return text(JSON.parse(source.slice(start, index)), MAXIMUM_FRAME_BYTES);
		}
		return failure();
	}
	function value(depth: number): void {
		space();
		if (depth > 32 || index >= source.length) failure();
		const first = source[index];
		if (first === '"') { string(); return; }
		if (first === "{" || first === "[") {
			index++;
			const end = first === "{" ? "}" : "]";
			const keys = new Set<string>();
			space();
			if (source[index] === end) { index++; return; }
			while (true) {
				if (first === "{") {
					const key = string();
					if (keys.has(key)) failure();
					keys.add(key);
					space();
					if (source[index++] !== ":") failure();
				}
				value(depth + 1); space();
				if (source[index] === end) { index++; return; }
				if (source[index++] !== ",") failure();
			}
		}
		const start = index;
		while (index < source.length && !/[\s,\]}]/.test(source[index])) index++;
		if (start === index) failure();
		JSON.parse(source.slice(start, index));
	}
	value(0); space();
	if (index !== source.length) failure();
	return JSON.parse(source);
}

export function dreamScopeOptions(value: unknown): DreamScopeOptions {
	const result = object(value);
	fields(result, ["deviceKey", "projectBindings"]);
	const deviceKey = result.deviceKey === null ? undefined : hash(result.deviceKey);
	const bindings = object(result.projectBindings);
	if (Object.keys(bindings).length > 64) failure();
	const projectBindings: Record<string, string> = {};
	for (const [path, key] of Object.entries(bindings)) {
		if (absolutePath(path) !== resolve(path)) failure();
		projectBindings[path] = hash(key);
	}
	return { ...(deviceKey === undefined ? {} : { deviceKey }), ...(Object.keys(projectBindings).length ? { projectBindings } : {}) };
}

export async function readDreamScope(signal: AbortSignal): Promise<DreamScopeOptions> {
	if (!process.env.PI_CORE_MEMORIES_DREAM_EXECUTABLE) await commandReady(signal);
	return new Promise((done, fail) => {
		execFile(dreamExecutable(), ["scope"], { signal, env: workerEnvironment(), timeout: 10_000, maxBuffer: 1_048_576, encoding: "buffer" }, (error, stdout) => {
			if (error) return fail(error);
			try { done(dreamScopeOptions(parseDreamJSON(stdout))); }
			catch (error) { fail(error); }
		});
	});
}

function selected(value: unknown): DreamSelection {
	const result = object(value);
	fields(result, ["provider", "modelID", "thinkingLevel"]);
	const selection = { provider: text(result.provider, 256), modelID: text(result.modelID, 256), thinkingLevel: text(result.thinkingLevel, 256) };
	if (!selection.provider || !selection.modelID || !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(selection.thinkingLevel)) failure();
	return selection;
}
function isSameSelection(left: DreamSelection, right: DreamSelection): boolean {
	return left.provider === right.provider && left.modelID === right.modelID && left.thinkingLevel === right.thinkingLevel;
}
function header(value: unknown, start: DreamStart): ObjectValue {
	const result = object(value);
	if (result.version !== 1 || result.invocationID !== start.invocationID) failure();
	return result;
}
export function dreamRequest(value: unknown, start: DreamStart): DreamRequest {
	const result = header(value, start);
	fields(result, ["version", "type", "invocationID", "requestID", "runID", "generation", "inputHash", "contextHash", "requestHash", "selection", "systemPrompt", "messages"]);
	if (result.type !== "modelRequest") failure();
	identifier(result.runID); identifier(result.requestID); generation(result.generation);
	hash(result.inputHash); hash(result.contextHash); hash(result.requestHash);
	if (result.requestID !== `${result.runID}:${result.requestHash}` || !isSameSelection(selected(result.selection), start.selection)) failure();
	text(result.systemPrompt, MAXIMUM_FRAME_BYTES);
	for (const message of list(result.messages, 1000)) {
		const item = object(message); fields(item, ["role", "text", "timestampMilliseconds"]);
		if (item.role !== "system" && item.role !== "user") failure();
		text(item.text, MAXIMUM_FRAME_BYTES);
		if (typeof item.timestampMilliseconds !== "number" || !Number.isSafeInteger(item.timestampMilliseconds)) failure();
	}
	return result as DreamRequest;
}
export function isMemoryPath(path: string): boolean {
	return /^(?:MEMORY\.md|projects\/[a-f0-9]{64}\.md|devices\/[a-f0-9]{64}\/(?:MEMORY\.md|projects\/[a-f0-9]{64}\.md))$/.test(path);
}

function sources(value: unknown): void {
	for (const source of list(value, 4096)) {
		const item = object(source); fields(item, ["sessionID", "entryID", "partIndex"]);
		const session = text(item.sessionID, MAXIMUM_FRAME_BYTES);
		const entry = text(item.entryID, MAXIMUM_FRAME_BYTES);
		if (!/^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/.test(session) || !/^[A-Za-z0-9_-]+$/.test(entry)) failure();
		integer(item.partIndex);
	}
}
export function dreamReport(value: unknown, start: DreamStart): DreamReport {
	const result = header(value, start);
	const isCallSelected = "callSelection" in result;
	fields(result, ["version", "type", "invocationID", "status", "generation", "runID", "base", "proposals", "notes", "isBacklog", "isRecovered", "reason", "detail", "unfinishedTails", ...isCallSelected ? ["callSelection"] : []]);
	if (isCallSelected && (result.status !== "pending" || result.reason !== "interruptedCall")) failure();
	if (isCallSelected) selected(result.callSelection);
	if (result.type !== "final" || !["completed", "pending", "noNewRecords", "busy", "blocked"].includes(String(result.status))) failure();
	generation(result.generation);
	if (result.runID !== null) identifier(result.runID);
	if (result.base !== null) commit(result.base);
	isBoolean(result.isBacklog); isBoolean(result.isRecovered); nullableText(result.reason, 256); nullableText(result.detail, 1024); integer(result.unfinishedTails, 32768);
	for (const proposal of list(result.proposals, 65)) {
		const item = object(proposal); fields(item, ["ref", "commit", "base", "path", "sources", "contradictions"]);
		commit(item.commit); commit(item.base);
		if (item.ref !== `refs/heads/proposals/${item.commit}` || item.base !== result.base || !isMemoryPath(text(item.path))) failure();
		sources(item.sources); text(item.contradictions, maximumTextBytes);
	}
	for (const note of list(result.notes, 1000)) {
		const item = object(note); fields(item, ["kind", "sources", "explanation", "reasonCode", "ownerReference", "contradictions"]);
		if (item.kind !== "noChange" && item.kind !== "ownerNote") failure();
		sources(item.sources); text(item.explanation, maximumTextBytes);
		if (item.kind === "noChange" && (!["notDurable", "alreadyRepresented", "insufficientEvidence", "unresolvedScope"].includes(String(item.reasonCode)) || item.ownerReference !== null)) failure();
		if (item.kind === "ownerNote" && (item.reasonCode !== null || item.ownerReference === null)) failure();
		nullableText(item.reasonCode, 256); nullableText(item.ownerReference, 256); text(item.contradictions, maximumTextBytes);
	}
	if ((result.status === "completed" || result.status === "pending") && (result.runID === null || result.base === null)) failure();
	if (["busy", "noNewRecords"].includes(String(result.status)) && (result.runID !== null || result.base !== null || (result.proposals as unknown[]).length || (result.notes as unknown[]).length)) failure();
	return result as DreamReport;
}

export function dreamExecutable(): string {
	const executable = process.env.PI_CORE_MEMORIES_DREAM_EXECUTABLE;
	if (!executable) return commandPath();
	if (!executable.startsWith("/") || executable.includes("\0") || Buffer.byteLength(executable) > 4096) {
		throw new Error("Invalid owned dream executable path.");
	}
	return executable;
}

export function workerEnvironment(environment: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
	return Object.fromEntries(["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"].flatMap((key) => environment[key] === undefined ? [] : [[key, environment[key]]]));
}

export async function runDreamWorker(start: DreamStart, call: DreamCall, signal: AbortSignal, onProgress: (coverage: DreamCoverage) => void = () => {}, protect?: DreamSourceProtectionCall): Promise<DreamReport> {
	if (signal.aborted) throw new Error("Dream cancelled.");
	if (!process.env.PI_CORE_MEMORIES_DREAM_EXECUTABLE) await commandReady(signal).catch(() => undefined);
	if (signal.aborted) throw new Error("Dream cancelled.");
	const initial = Buffer.from(JSON.stringify(start) + "\n");
	if (initial.length > 65_536) failure();
	const worker = spawn(dreamExecutable(), ["dream-worker"], { stdio: "pipe", env: workerEnvironment() });
	const controller = new AbortController();
	let final: DreamReport | undefined;
	let coverage: DreamCoverage | undefined;
	let progressFrames = 0;
	let protectionExchanges = 0;
	let isProtecting = false;
	let isProtectionChecked = false;
	let isProtectionBlocked = false;
	let request: DreamRequest | undefined;
	let isReplySent = false;
	let isCancelled = false;
	let isClosed = false;
	let error: Error | undefined;
	let frameParts: Buffer[] = [];
	let frameBytes = 0;
	let total = 0;
	let stderr = "";
	let modelError: string | undefined;
	let terminate: ReturnType<typeof setTimeout> | undefined;
	let kill: ReturnType<typeof setTimeout> | undefined;
	let finishTimer: ReturnType<typeof setTimeout> | undefined;
	function stop(): void {
		if (terminate || isClosed) return;
		terminate = setTimeout(() => {
			if (isClosed) return;
			worker.kill("SIGTERM");
			kill = setTimeout(() => { if (!isClosed) worker.kill("SIGKILL"); }, 1000);
		}, 1000);
	}
	function rejectTransport(_cause: unknown): void {
		error ??= new Error("Dream worker private protocol failed.");
		controller.abort();
		worker.stdin.destroy(); stop();
	}
	function send(value: unknown, limit = maximumReplyBytes): void {
		const bytes = Buffer.from(JSON.stringify(value) + "\n");
		if (bytes.length > limit || isClosed || worker.stdin.destroyed) return rejectTransport("reply could not be sent");
		worker.stdin.write(bytes, (writeError) => { if (writeError) rejectTransport(writeError); });
	}
	function cancel(): void {
		if (isCancelled || isClosed) return;
		isCancelled = true; controller.abort();
		send({ version: 1, type: "cancel", invocationID: start.invocationID });
		stop();
	}
	async function answer(current: DreamRequest): Promise<void> {
		let response: ObjectValue;
		const binding = { version: 1, invocationID: start.invocationID, requestID: current.requestID, runID: current.runID, inputHash: current.inputHash, contextHash: current.contextHash, requestHash: current.requestHash };
		try {
			const result = await call(current, controller.signal);
			if (controller.signal.aborted) return;
			if (!result || !isWellFormedText(result) || Buffer.byteLength(result) > maximumTextBytes) failure();
			response = { ...binding, type: "modelResponse", text: result };
		} catch (error) {
			if (controller.signal.aborted) return;
			modelError = error instanceof DreamCallFailure ? error.message : "The dream model call did not complete.";
			response = { ...binding, type: "modelFailure", category: "incomplete" };
		}
		if (final || isClosed || error || isReplySent) return rejectTransport("model reply arrived after the run ended");
		isReplySent = true; send(response);
	}
	async function answerProtection(value: unknown): Promise<void> {
		try {
			if (!protect) throw new Error("Source protection is unavailable.");
			const result = await protect(value, controller.signal);
			if (controller.signal.aborted) return;
			if (final || isClosed || error) return rejectTransport("Source protection ended too late.");
			isProtectionChecked = result.status === "checked";
			isProtectionBlocked ||= result.status === "blocked";
			isProtecting = false;
			send(result, SOURCE_PROTECTION_REPLY_BYTES);
		} catch (cause) { rejectTransport(cause); }
	}
	function consume(bytes: Buffer): void {
		const value = parseDreamJSON(bytes);
		const item = object(value);
		if (final || error || isProtecting) failure();
		if (item.type === "sourceProtectionRequest") {
			if (isCancelled || (request && !isReplySent) || ++protectionExchanges > 16) failure();
			isProtecting = true;
			void answerProtection(value);
		} else if (item.type === "progress") {
			const next = dreamCoverage(value, start);
			if (++progressFrames > 2 || (progressFrames === 1 && (request || next.completedBytes !== 0)) || (progressFrames === 2 && request && !isReplySent && !isCancelled) || (coverage && (next.completedBytes !== next.plannedBytes || JSON.stringify({ ...next, completedBytes: 0 }) !== JSON.stringify({ ...coverage, completedBytes: 0 })))) failure();
			coverage = next; onProgress(next);
		} else if (item.type === "modelRequest") {
			if (request || isCancelled || !isProtectionChecked || isProtectionBlocked) failure();
			request = dreamRequest(value, start);
			void answer(request);
		} else {
			if (request && !isReplySent && !isCancelled) failure();
			final = dreamReport(value, start);
			if (final.detail === null && modelError) final.detail = modelError;
			if (coverage && ((final.status === "completed" && coverage.completedBytes !== coverage.plannedBytes) || (final.status !== "completed" && coverage.completedBytes !== 0))) failure();
			if (request && (final.runID !== request.runID || final.base === null || (final.status !== "completed" && final.status !== "pending" && final.status !== "blocked") || BigInt(final.generation) !== BigInt(request.generation) + (final.status === "completed" ? 1n : 0n))) failure();
			finishTimer = setTimeout(() => rejectTransport("worker did not exit after its final report"), 2000);
		}
	}
	worker.stdin.on("error", (cause) => rejectTransport(cause));
	worker.stdout.on("data", (chunk: Buffer) => {
		try {
			if (total > maximumAggregateBytes - chunk.length) failure();
			total += chunk.length;
			let offset = 0;
			while (offset < chunk.length) {
				const newline = chunk.indexOf(10, offset);
				const end = newline < 0 ? chunk.length : newline;
				const size = end - offset;
				if (frameBytes > MAXIMUM_FRAME_BYTES - size) failure();
				if (size) { frameParts.push(chunk.subarray(offset, end)); frameBytes += size; }
				if (newline < 0) break;
				consume(Buffer.concat(frameParts, frameBytes));
				frameParts = []; frameBytes = 0; offset = newline + 1;
			}
		} catch (cause) { rejectTransport(cause); }
	});
	worker.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); if (stderr.length > 8192) rejectTransport("worker wrote more than 8 KB to stderr"); });
	const completion = new Promise<DreamReport>((done, fail) => {
		worker.once("error", (cause) => rejectTransport(cause));
		worker.once("close", (code, exitSignal) => {
			isClosed = true; controller.abort();
			if (terminate) clearTimeout(terminate);
			if (kill) clearTimeout(kill);
			if (finishTimer) clearTimeout(finishTimer);
			signal.removeEventListener("abort", cancel);
			const output = stderr.trim() === "dream-worker: dream storage limit exceeded" ? " · stderr: dream-worker: dream storage limit exceeded" : stderr.trim() ? " · worker wrote a private diagnostic" : "";
			if (error) fail(new Error(error.message + output));
			else if (code !== 0 || exitSignal || frameBytes || !final) fail(new Error(`Dream worker exited (${exitSignal ?? `code ${code}`}) without a final report${output}`));
			else done(final);
		});
	});
	worker.stdin.write(initial, (writeError) => { if (writeError) rejectTransport(writeError); });
	signal.addEventListener("abort", cancel, { once: true });
	if (signal.aborted) cancel();
	return completion;
}

export class DreamCallFailure extends Error {}
export async function callDreamModel(request: DreamRequest, ctx: Pick<ExtensionContext, "modelRegistry">, model: NonNullable<ExtensionContext["model"]>, selection: DreamSelection, signal: AbortSignal): Promise<string> {
	function modelFailure(cause: string): never { throw new DreamCallFailure(`Dream model call failed: ${cause}`); }
	function incompleteResponse(reason: AssistantMessage["stopReason"], errorMessage?: string): never {
		const causes = { stop: "unexpected stop reason", length: "response reached the output token limit", toolUse: "unexpected tool call", error: "provider error", aborted: "provider aborted the response", pending: "response is pending", deferred: "response was deferred" };
		const diagnostic = reason === "error" || reason === "aborted"
			? typeof errorMessage === "string" && errorMessage.trim() ? `: ${Buffer.from(escapeDreamDisplay(errorMessage.slice(0, 800))).subarray(0, 800).toString()}` : " (no error message)"
			: "";
		return modelFailure((causes[reason] ?? "unknown stop reason") + diagnostic);
	}
	if (signal.aborted) throw new Error("Dream call cancelled.");
	if (!isSameSelection(request.selection, selection) || model.provider !== selection.provider || model.id !== selection.modelID) modelFailure("model selection does not match the request");
	if (model.api === "pi-virtual" || !ctx.modelRegistry.isUsingOAuth(model) || ctx.modelRegistry.getProvider(model.provider)?.auth.oauth?.isSubscription !== true) modelFailure("the selected model is not using a subscription sign-in; nothing was dispatched");
	const context: Context = { systemPrompt: request.systemPrompt, messages: request.messages.map((message) => ({ role: message.role, content: message.text, timestamp: message.timestampMilliseconds })) };
	const reasoning = selection.thinkingLevel === "off" ? undefined : selection.thinkingLevel as "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
	const controller = new AbortController();
	const abort = () => controller.abort();
	signal.addEventListener("abort", abort, { once: true });
	let rejectAbort!: (reason: Error) => void;
	const cancelled = new Promise<never>((_done, fail) => { rejectAbort = fail; });
	let isDispatchInvalid = false;
	controller.signal.addEventListener("abort", () => rejectAbort(isDispatchInvalid ? new DreamCallFailure("Dream model call failed: physical dispatch changed or was invalid") : new Error("Dream call cancelled.")), { once: true });
	void cancelled.catch(() => {});
	let dispatch: { provider: string; modelID: string; api: string } | undefined;
	const onDispatch = (physical: { provider: string; modelID: string; api: string }) => {
		try {
			const observed = { provider: text(physical.provider, 256), modelID: text(physical.modelID, 256), api: text(physical.api, 256) };
			if (!["openai", "openai-codex", "anthropic"].includes(observed.provider) || !observed.modelID || !observed.api || observed.api === "pi-virtual") failure();
			if (model.api !== "pi-virtual" && (observed.provider !== model.provider || observed.modelID !== model.id || observed.api !== model.api)) failure();
			if (dispatch && (dispatch.provider !== observed.provider || dispatch.modelID !== observed.modelID || dispatch.api !== observed.api)) failure();
			dispatch = observed;
		} catch { isDispatchInvalid = true; controller.abort(); modelFailure("physical dispatch changed or was invalid"); }
	};
	function isExpectedIdentity(message: AssistantMessage): boolean {
		return !isDispatchInvalid && dispatch !== undefined && message.provider === dispatch.provider && message.model === dispatch.modelID && message.api === dispatch.api;
	}
	try {
	onDispatch({ provider: model.provider, modelID: model.id, api: model.api });
	const stream = ctx.modelRegistry.streamSimple(model, context, { signal: controller.signal, reasoning });
	let terminal: AssistantMessage | undefined;
	let isDone = false;
	const iterator = stream[Symbol.asyncIterator]();
	while (true) {
		const next = await Promise.race([iterator.next(), cancelled]);
		if (next.done) break;
		const event = next.value;
		if (signal.aborted) throw new Error("Dream call cancelled.");
		if (isDone) modelFailure("stream continued after its terminal event");
		if (event.type.startsWith("toolcall")) modelFailure("unexpected tool call");
		if (event.type === "error") incompleteResponse(event.reason, event.error.errorMessage);
		if ("partial" in event) {
			let bytes = 0;
			for (const part of event.partial.content) {
				if (part.type === "thinking") continue;
				if (part.type !== "text") modelFailure("unexpected non-text response content");
				bytes += Buffer.byteLength(part.text);
				if (bytes > maximumTextBytes) modelFailure(`response exceeded the ${maximumTextBytes}-byte text limit`);
			}
		}
		if (event.type === "done") {
			if (event.reason !== "stop") incompleteResponse(event.reason);
			if (!isExpectedIdentity(event.message)) modelFailure("response identity does not match the dispatched model");
			terminal = event.message; isDone = true;
		}
	}
	if (signal.aborted) throw new Error("Dream call cancelled.");
	if (!isDone || !terminal) modelFailure("stream ended without a terminal response");
	const result = await Promise.race([stream.result(), cancelled]);
	function completed(message: AssistantMessage): string {
		if (message.stopReason !== "stop") incompleteResponse(message.stopReason, message.errorMessage);
		if (!isExpectedIdentity(message)) modelFailure("response identity does not match the dispatched model");
		let bytes = 0;
		const blocks: string[] = [];
		for (const part of message.content) {
			if (part.type === "thinking") continue;
			if (part.type !== "text") modelFailure("unexpected non-text response content");
			if (!isWellFormedText(part.text)) modelFailure("response text contains invalid Unicode");
			bytes += Buffer.byteLength(part.text);
			if (bytes > maximumTextBytes) modelFailure(`response exceeded the ${maximumTextBytes}-byte text limit`);
			blocks.push(part.text);
		}
		if (!bytes) modelFailure("response contained no text");
		return blocks.join("");
	}
	const resultText = completed(result);
	if (completed(terminal) !== resultText) modelFailure("terminal and final response text do not match");
	if (signal.aborted) throw new Error("Dream call cancelled.");
	return resultText;
	} finally { signal.removeEventListener("abort", abort); controller.abort(); }
}

function absolutePath(value: unknown): string {
	const result = text(value);
	if (!result.startsWith("/")) failure();
	return result;
}
async function optionalDirectory(path: string): Promise<string | null> {
	try { if (!(await lstat(path)).isDirectory()) failure(); return path; }
	catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return null; throw error; }
}
function isInstalledSnippets(path: string, home: string): boolean {
	const prefix = join(home, ".cache", "tool-sync", "installs") + "/";
	if (!path.startsWith(prefix) || resolve(path) !== path) return false;
	const parts = path.slice(prefix.length).split("/");
	return parts.length === 9 && /^[A-Za-z0-9_-]+$/.test(parts[0]!) && parts.slice(1, 4).join("/") === "home/.local/lib" && ["agents-runtime", "agents-resources"].includes(parts[4]!) && parts.slice(5).join("/") === "pi/extensions/prompt-snippets/snippets";
}

export async function dreamRoots(agentDir: string, cwd: string, home = homedir()): Promise<DreamRoots> {
	const roots: DreamRoots = {
		state: join(home, ".local", "state", "pi-core-memories"), sessions: join(agentDir, "sessions"),
		memory: process.env.PI_CORE_MEMORIES_REPO ? resolve(cwd, process.env.PI_CORE_MEMORIES_REPO) : join(home, ".local", "share", "pi-core-memories"),
		snippets: join(agentDir, "extensions", "prompt-snippets", "snippets"), prompts: join(agentDir, "prompts"), globalAgents: join(agentDir, "AGENTS.md"),
	};
	try {
		const metadata = await lstat(roots.state);
		if (!metadata.isDirectory() || (metadata.mode & 0o777) !== 0o700 || metadata.uid !== process.getuid?.()) failure();
	}
	catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
		roots.snippets = await optionalDirectory(roots.snippets!); roots.prompts = await optionalDirectory(roots.prompts!);
		return roots;
	}
	const file = await open(join(roots.state, "root.json"), constants.O_RDONLY | constants.O_NOFOLLOW);
	try {
		const metadata = await file.stat();
		if (!metadata.isFile() || metadata.nlink !== 1 || (metadata.mode & 0o777) !== 0o600 || metadata.uid !== process.getuid?.() || metadata.size > 1_048_576) failure();
		const buffer = Buffer.alloc(metadata.size + 1);
		let count = 0;
		while (count < buffer.length) {
			const result = await file.read(buffer, count, buffer.length - count, null);
			if (result.bytesRead === 0) break;
			count += result.bytesRead;
		}
		if (count !== metadata.size) failure();
		const binding = object(parseDreamJSON(buffer.subarray(0, count)));
		const keys = ["schemaVersion", "sessions", "memory", "stripping"];
		if ("globalAgents" in binding) keys.push("globalAgents");
		if ("originalRoots" in binding) keys.push("originalRoots");
		fields(binding, keys);
		if (binding.schemaVersion !== 2) failure();
		const canonical = [absolutePath(binding.sessions), absolutePath(binding.memory), ...list(binding.stripping, 2).map(absolutePath)];
		const configured = binding.originalRoots === undefined ? canonical : list(binding.originalRoots, 4).map(absolutePath);
		if (configured.length !== canonical.length || configured[0] !== roots.sessions || configured[1] !== roots.memory || binding.globalAgents !== roots.globalAgents) failure();
		const stripping = configured.slice(2);
		const isSnippet = (path: string): boolean => path === roots.snippets || isInstalledSnippets(path, home);
		if (new Set(stripping).size !== stripping.length || stripping.some((path) => !isSnippet(path) && path !== roots.prompts) || (stripping.length === 2 && (!isSnippet(stripping[0]!) || stripping[1] !== roots.prompts))) failure();
		if (!stripping.some(isSnippet)) roots.snippets = null;
		if (!stripping.includes(roots.prompts!)) roots.prompts = null;
		return roots;
	} finally { await file.close(); }
}

export function escapeDreamDisplay(value: string): string {
	return value.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/gu, (character) => `\\u{${character.codePointAt(0)!.toString(16).toUpperCase()}}`);
}
const dreamReasons: Record<string, string> = {
	cancelled: "You cancelled the run.",
	workerFailure: "The worker hit an error before it finished.",
	protocolFailure: "The worker and the extension disagreed on the protocol.",
	callbackFailure: "The model call failed before its reply was saved.",
	interruptedCall: "A model call was interrupted before its reply was saved.",
	invalidDecision: "The saved model reply failed validation.",
	staleUnpublishedPlans: "Saved proposals are waiting for saved-suggestion recovery in the Mac app.",
	droppedBatch: "Proposals were dropped because approved memory or rejected findings changed before the batch was published; the evidence will be dreamt again.",
};
const noteReasons: Record<string, string> = {
	notDurable: "not a durable preference", alreadyRepresented: "already in memory", insufficientEvidence: "not enough evidence", unresolvedScope: "unclear which project it belongs to",
};
function plural(count: number, noun: string): string { return `${count} ${noun}${count === 1 ? "" : "s"}`; }
export function dreamReviewText(report: DreamReport): string {
	const lines = [`Dream: ${report.status} · generation ${report.generation}${report.isRecovered ? " · recovered" : ""}`];
	if (report.reason) lines.push(dreamReasons[report.reason] ?? escapeDreamDisplay(report.reason));
	if (report.detail) lines.push(`Cause: ${escapeDreamDisplay(report.detail)}`);
	if (report.status === "completed") lines.push(report.proposals.length ? `${plural(report.proposals.length, "proposal")} saved for review in conversation. Memory is unchanged.` : "No proposals this time.");
	if (report.status === "pending") {
		if (report.reason === "invalidDecision") lines.push("Memory was not changed. The saved reply did not pass validation. Discuss the retained work in conversation before requesting a replacement model call.");
		else lines.push("Memory was not changed. The interrupted call and saved work are retained. Discuss recovery in conversation before another model call.");
	}
	if (report.isBacklog) lines.push("More sessions remain in the background intake queue.");
	if (report.unfinishedTails) lines.push(`Sessions still in progress, skipped for now: ${report.unfinishedTails}`);
	function cited(items: DreamSource[]): string { return `${plural(items.length, "source")} in ${plural(new Set(items.map((source) => source.sessionID)).size, "session")}`; }
	for (const proposal of report.proposals) {
		lines.push(`\nProposal for ${proposal.path} · ${cited(proposal.sources)}`);
		if (proposal.contradictions) lines.push(`Contradictions: ${escapeDreamDisplay(proposal.contradictions)}`);
	}
	const skipped = report.notes.filter((note) => note.kind === "noChange");
	if (skipped.length) {
		lines.push(`\nSkipped: ${plural(skipped.length, "group")}`);
		for (const [reason, label] of Object.entries(noteReasons)) {
			const count = skipped.filter((note) => note.reasonCode === reason).length;
			if (count) lines.push(`• ${label}: ${count}`);
		}
	}
	for (const note of report.notes.filter((note) => note.kind === "ownerNote")) {
		const label = note.kind === "ownerNote" ? `belongs to ${escapeDreamDisplay((note.ownerReference ?? "its owner").split(" ")[0]!)}` : noteReasons[note.reasonCode ?? ""] ?? escapeDreamDisplay(note.reasonCode ?? note.kind);
		lines.push(`• ${label} · ${cited(note.sources)}`, `  ${escapeDreamDisplay(note.explanation)}`);
		if (note.contradictions) lines.push(`  Contradictions: ${escapeDreamDisplay(note.contradictions)}`);
	}
	return lines.join("\n");
}

export function registerDreamHistory(pi: ExtensionAPI): void {
	pi.registerEntryRenderer<{ report: DreamReport; memory: string; coverage?: DreamCoverage; elapsedSeconds?: number }>(DREAM_REVIEW_TYPE, (entry) => {
		try {
			if (!entry.data) return undefined;
			const report = dreamReport({ ...entry.data.report, detail: entry.data.report.detail ?? null }, { invocationID: identifier(entry.data.report.invocationID) } as DreamStart);
			const coverage = entry.data.coverage === undefined ? undefined : savedDreamCoverage(entry.data.coverage, { invocationID: report.invocationID } as DreamStart);
			const elapsedSeconds = entry.data.elapsedSeconds;
			if (elapsedSeconds !== undefined && (typeof elapsedSeconds !== "number" || !Number.isFinite(elapsedSeconds) || elapsedSeconds < 0)) failure();
			return progressComponent((width) => dreamReviewText(report) + (coverage ? "\n" + dreamProgressText(coverage, elapsedSeconds, report.status, width) : ""));
		} catch { return new Text("Dream review unavailable.", 0, 0); }
	});
}
