import { randomUUID } from "node:crypto";
import { isAbsolute } from "node:path";
import { getAgentDir, type ExtensionAPI, type ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { callDreamModel, dreamBatchTextBytes, dreamRoots, dreamScopeOptions, escapeDreamDisplay, parseDreamJSON, readDreamScope, runDreamWorker, type DreamRoots, type DreamScopeOptions, type DreamSelection, type DreamStart } from "./dream.ts";

type ControlRequest = { operation: "start" | "all" | "retry" | "replace"; roots: DreamRoots | null } & DreamScopeOptions;

export function parseControlRequest(text: string): ControlRequest {
	if (Buffer.byteLength(text) > 65_536) throw new Error("Dream control request is too large.");
	const value = parseDreamJSON(Buffer.from(text)) as Record<string, unknown>;
	if (!value || Array.isArray(value) || typeof value !== "object"
		|| !Object.hasOwn(value, "roots") || Object.keys(value).some((key) => !["operation", "roots", "deviceKey", "projectBindings"].includes(key))
		|| typeof value.operation !== "string" || !["start", "all", "retry", "replace"].includes(value.operation)) {
		throw new Error("Use a dream control request with operation and roots.");
	}
	if (value.roots !== null) {
		if (!value.roots || typeof value.roots !== "object" || Array.isArray(value.roots)) throw new Error("Invalid dream roots.");
		const roots = value.roots as Record<string, unknown>;
		if (Object.keys(roots).sort().join(",") !== "globalAgents,memory,prompts,sessions,snippets,state") throw new Error("Invalid dream root fields.");
		for (const [name, path] of Object.entries(roots)) {
			if (path === null && ["snippets", "prompts", "globalAgents"].includes(name)) continue;
			if (typeof path !== "string" || !isAbsolute(path) || path.includes("\0") || Buffer.byteLength(path) > 4096) throw new Error("Dream roots must be bounded absolute paths.");
		}
	}
	if (("deviceKey" in value && value.deviceKey === null) || ("projectBindings" in value && value.projectBindings === null)) throw new Error("Invalid device scope options.");
	dreamScopeOptions({ deviceKey: value.deviceKey ?? null, projectBindings: value.projectBindings ?? {} });
	return value as ControlRequest;
}

function detail(error: unknown): string {
	let text = error instanceof Error ? error.message : String(error);
	for (const [name, value] of Object.entries(process.env)) {
		if (/(?:KEY|TOKEN|SECRET|PASSWORD)/i.test(name) && value && value.length >= 8) text = text.split(value).join("[redacted]");
	}
	text = text.replace(/\bBearer\s+[^\s"']+/gi, "Bearer [redacted]").replace(/\bsk-[A-Za-z0-9_-]{12,}/g, "[redacted]");
	let result = "";
	let bytes = 0;
	for (const character of escapeDreamDisplay(text)) {
		const length = Buffer.byteLength(character);
		if (bytes + length > 1000) break;
		result += character;
		bytes += length;
	}
	return result;
}

export function registerDreamControl(
	pi: ExtensionAPI,
	run = runDreamWorker,
	rootsFor = dreamRoots,
	call = callDreamModel,
	scopeFor = readDreamScope,
): () => Promise<void> {
	let controller: AbortController | undefined;
	let work: Promise<void> | undefined;
	let isShuttingDown = false;
	const emit = (ctx: ExtensionCommandContext, event: string, fields: Record<string, unknown>) => {
		ctx.ui.notify(JSON.stringify({ version: 1, type: "core-memory-control", event, ...fields }), event === "error" ? "error" : "info");
	};
	const abort = async () => { controller?.abort(); await work; };
	pi.registerCommand("memory-dream-cancel", {
		description: "Cancel only the dream invocation owned by this Pi process",
		handler: async (args, ctx) => {
			if (args.trim()) { emit(ctx, "error", { detail: "Cancel takes no arguments." }); return; }
			await abort();
		},
	});
	pi.registerCommand("memory-dream-control", {
		description: "Run one explicit dream operation for the native memory app or command interface",
		handler: async (args, ctx) => {
			if (ctx.mode !== "rpc") { emit(ctx, "error", { detail: "Dream control requires Pi RPC mode." }); return; }
			if (isShuttingDown || controller) { emit(ctx, "error", { detail: "Dream control is busy." }); return; }
			let request: ControlRequest;
			try { request = parseControlRequest(args); }
			catch (error) { emit(ctx, "error", { detail: detail(error) }); return; }
			const current = new AbortController();
			controller = current;
			const perform = async () => {
				let cancelIdle!: () => void;
				const cancelled = new Promise<never>((_done, fail) => {
					cancelIdle = () => fail(new Error("Dream cancelled before it started."));
					current.signal.addEventListener("abort", cancelIdle, { once: true });
				});
				try { await Promise.race([ctx.waitForIdle(), cancelled]); }
				finally { current.signal.removeEventListener("abort", cancelIdle); }
				if (current.signal.aborted) throw new Error("Dream cancelled before it started.");
				const model = ctx.model;
				if (!model) throw new Error("Dream needs a selected model.");
				const batchTextBytes = dreamBatchTextBytes(model.contextWindow);
				if (batchTextBytes === null) throw new Error("Dream needs at least 65,536 tokens of context.");
				const selection: DreamSelection = { provider: model.provider, modelID: model.id, thinkingLevel: ctx.thinkingLevel ?? pi.getThinkingLevel() };
				if (!["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(selection.thinkingLevel)) throw new Error("Dream needs an explicit supported thinking level.");
				const roots = request.roots ?? await rootsFor(getAgentDir(), ctx.cwd);
				const scope = request.deviceKey !== undefined || request.projectBindings !== undefined
					? dreamScopeOptions({ deviceKey: request.deviceKey ?? null, projectBindings: request.projectBindings ?? {} })
					: request.roots === null ? await scopeFor(current.signal) : {};
				if (current.signal.aborted) throw new Error("Dream cancelled before it started.");
				emit(ctx, "selection", { selection });
				while (!current.signal.aborted) {
					emit(ctx, "phase", { phase: "planning" });
					const start: DreamStart = {
						version: 1, type: "start", invocationID: randomUUID(), roots, selection,
						resume: request.operation === "replace" ? "replaceInvalidResponse" : request.operation === "retry" ? "retryInterruptedCall" : "inspectOrContinue",
						batchTextBytes, ...scope,
					};
					const report = await run(start, async (saved, signal) => {
						emit(ctx, "phase", { phase: "modelCall" });
						try { return await call(saved, ctx, model, selection, signal); }
						finally { if (!current.signal.aborted) emit(ctx, "phase", { phase: "saving" }); }
					}, current.signal, (coverage) => emit(ctx, "progress", { coverage }));
					const isContinuing = request.operation === "all" && report.status === "completed" && report.isBacklog && !current.signal.aborted;
					const displayed = report.detail === null ? report : { ...report, detail: detail(report.detail) };
					emit(ctx, isContinuing ? "batchReport" : "report", { report: displayed });
					if (!isContinuing) return;
				}
			};
			const pending = perform().catch((error) => emit(ctx, "error", { detail: detail(error) }));
			work = pending;
			try { await pending; }
			finally { if (controller === current) { controller = undefined; work = undefined; } }
		},
	});
	pi.on("session_shutdown", async () => { isShuttingDown = true; await abort(); });
	return abort;
}

export default function memoryDreamControl(pi: ExtensionAPI): void {
	registerDreamControl(pi);
}
