import { execFile, spawn } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { Writable } from "node:stream";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { commandPath, commandReady } from "./command.ts";
import { escapeDreamDisplay, parseDreamJSON } from "./dream.ts";
import { chooseApprovedReview } from "./approved-review.ts";

export type ReviewCatalog = {
	catalog: { base: string; entries: { path: string; expected: string; reviewed?: string; revised?: string; isMutable: boolean; limitation?: string }[] };
	due: number[];
};

export async function reviewCatalog(repo: string, cwd: string, signal?: AbortSignal): Promise<ReviewCatalog> {
	await commandReady();
	return new Promise((done, fail) => {
		execFile(commandPath(), ["review-catalog", "--repo", repo, "--cwd", cwd], {
			cwd, env: environment(), signal, timeout: 10_000, maxBuffer: 32 * 1024 * 1024, encoding: "buffer",
		}, (error, stdout) => {
			if (error) return fail(error);
			try { done(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(stdout))); }
			catch (error) { fail(error); }
		});
	});
}

function repository(ctx: ExtensionContext): string {
	return process.env.PI_CORE_MEMORIES_REPO
		? resolve(ctx.cwd, process.env.PI_CORE_MEMORIES_REPO)
		: join(homedir(), ".local", "share", "pi-core-memories");
}

function environment(): NodeJS.ProcessEnv {
	return Object.fromEntries(["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL"].flatMap((key) => process.env[key] === undefined ? [] : [[key, process.env[key]]]));
}

export async function manageMemory(repo: string, cwd: string, request: object, signal?: AbortSignal): Promise<unknown> {
	const input = JSON.stringify(request);
	if (Buffer.byteLength(input) > 1_048_576) throw new Error("Memory request is too large.");
	await commandReady();
	return new Promise((done, fail) => {
		const child = execFile(commandPath(), ["manage", "--repo", repo], {
			cwd, env: environment(), signal, timeout: 30_000, maxBuffer: 32 * 1024 * 1024, encoding: "buffer",
		}, (error, stdout, stderr) => {
			if (error) return fail(new Error(`Memory operation did not return a receipt. Read current entries before retrying a change. ${stderr.toString("utf8") || error.message}`));
			try { done(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(stdout))); }
			catch { fail(new Error("Invalid memory result. Read current entries before retrying a change.")); }
		});
		child.stdin?.on("error", () => {});
		child.stdin?.end(input);
	});
}

const target = {
	base: Type.String({ description: "Exact approved base from memory_list." }),
	path: Type.String({ description: "Exact committed memory path from memory_list." }),
	locator: Type.Object({ start: Type.Integer({ minimum: 0 }), end: Type.Integer({ minimum: 1 }) }, { additionalProperties: false }),
	expected: Type.String({ description: "Exact entry bytes from memory_list, including annotations and line endings. Never search by duplicate prose." }),
};
const replacement = Type.String({ description: "One complete annotated Markdown entry, without memory-id, reviewed, or revised metadata. Retain every old source annotation on update; add references for the requested correction." });
const reason = Type.String({ minLength: 1, maxLength: 16_384, description: "Reason for the explicit user-requested entry change. Do not copy transcripts or credentials." });
const permission = "Use only for an explicit user's requested change to this approved entry. Never use for dream-generated candidates, inferred preferences, or background consolidation. Pending dream candidates require native /mem-review. This is an agent-facing permission rule, not proof of human identity. No second entry approval is required. If attached checkout blocks the change, ask the user to run /mem-prepare. Changes load in a new session, not this session's saved snapshot.";

export function registerMemoryManagement(pi: ExtensionAPI): () => Promise<void> {
	for (const tool of [
		{ name: "memory_list", operation: "list", description: "List the bounded committed approved memory catalog with exact bases, locators, bytes, identities and dates. Excludes pending dream candidates.", parameters: Type.Object({}, { additionalProperties: false }) },
		{ name: "memory_get", operation: "get", description: "Get one approved entry at the exact listed base, locator and expected bytes. Does not read dream candidates.", parameters: Type.Object(target, { additionalProperties: false }) },
		{ name: "memory_add", operation: "add", description: `Add one approved memory entry. ${permission}`, parameters: Type.Object({ base: target.base, path: Type.String({ description: "MEMORY.md, projects/<project key>.md, devices/<device key>/MEMORY.md, or devices/<device key>/projects/<project key>.md. Obtain exact 64 lowercase hex keys from the catalog or scope command. Never guess them." }), replacement, reason }, { additionalProperties: false }) },
		{ name: "memory_update", operation: "update", description: `Update one exact approved memory entry, preserving identity and source annotations. ${permission}`, parameters: Type.Object({ ...target, replacement, reason }, { additionalProperties: false }) },
		{ name: "memory_delete", operation: "delete", description: `Delete only the exact approved entry, retaining its previous bytes and references in the direct-change audit. ${permission}`, parameters: Type.Object({ ...target, reason }, { additionalProperties: false }) },
	]) {
		pi.registerTool({
			name: tool.name, label: tool.name, description: tool.description, parameters: tool.parameters,
			executionMode: "sequential",
			async execute(_id, params, signal, _update, ctx) {
				const result = await manageMemory(repository(ctx), ctx.cwd, { ...params, operation: tool.operation }, signal);
				const text = JSON.stringify(result).replace(/[\u202a-\u202e\u2066-\u2069]/g, (value) => `\\u${value.charCodeAt(0).toString(16).padStart(4, "0")}`);
				return { content: [{ type: "text", text }], details: result };
			},
		});
	}
	let active: AbortController | undefined;
	let pending: Promise<void> | undefined;
	pi.registerCommand("mem-rereview", {
		description: "Review an existing approved memory without dream material",
		async handler(args, ctx) {
			if (args.trim() || ctx.mode !== "tui" || !ctx.hasUI) throw new Error("/mem-rereview requires terminal mode and no arguments.");
			if (active) throw new Error("Native memory review is already open.");
			active = new AbortController();
			const signal = active.signal;
			pending = (async () => {
				await ctx.waitForIdle();
				signal.throwIfAborted();
				const result = await reviewCatalog(repository(ctx), ctx.cwd, signal);
				const labels = result.catalog.entries.map((entry, index) => `${index + 1}. ${entry.path} — ${result.due.includes(index) ? "Review due" : "Reviewed"} — ${escapeDreamDisplay(entry.expected).slice(0, 120)}`);
				const choice = await ctx.ui.select("Approved memories", ["Back", ...labels], { signal });
				const index = choice ? labels.indexOf(choice) : -1;
				if (index >= 0) await prepareCheckout(ctx, signal, { base: result.catalog.base, entry: index });
			})();
			try { await pending; } finally { active = undefined; pending = undefined; }
		},
	});
	pi.registerCommand("mem-prepare", {
		description: "Prepare the private memory checkout after a separate native confirmation; does not approve or change memory",
		async handler(args, ctx) {
			if (args.trim() || ctx.mode !== "tui" || !ctx.hasUI) throw new Error("/mem-prepare requires terminal mode and no arguments.");
			if (active) throw new Error("Memory preparation is already open.");
			active = new AbortController();
			const signal = active.signal;
			pending = (async () => {
				await ctx.waitForIdle();
				signal.throwIfAborted();
				await prepareCheckout(ctx, signal);
			})();
			try { await pending; } finally { active = undefined; pending = undefined; }
		},
	});
	return async () => { active?.abort(); await pending?.catch(() => {}); };
}

async function prepareCheckout(ctx: ExtensionContext, signal: AbortSignal, selection?: { base: string; entry: number }): Promise<void> {
	await commandReady();
	const child = spawn(commandPath(), ["memory-prepare-worker"], {
		cwd: ctx.cwd, env: environment(), stdio: ["ignore", "pipe", "pipe", "pipe"], signal,
	});
	const previewController = new AbortController();
	const previewSignal = AbortSignal.any([signal, previewController.signal]);
	const control = child.stdio[3] as Writable;
	control.on("error", () => {});
	let processError: Error | undefined;
	let isClosed = false;
	let termination: ReturnType<typeof setTimeout> | undefined;
	let buffer = Buffer.alloc(0);
	let aggregate = 0;
	const frameLimit = selection ? 2 * 1_048_576 : 65_536;
	const frames: Record<string, unknown>[] = [];
	let wake: (() => void) | undefined;
	let failTransport!: (error: Error) => void;
	const failure = new Promise<never>((_done, fail) => { failTransport = fail; });
	void failure.catch(() => {});
	function terminate(): void {
		if (isClosed || termination) return;
		child.kill("SIGTERM");
		termination = setTimeout(() => {
			if (!isClosed) child.kill("SIGKILL");
			child.stdout!.destroy();
			child.stderr!.destroy();
			control.destroy();
		}, 1000);
	}
	function fail(error: Error): void {
		processError ??= error;
		failTransport(processError);
		wake?.();
		terminate();
	}
	const closed = new Promise<void>((done) => {
		child.on("error", fail);
		child.on("close", (code) => {
			isClosed = true;
			clearTimeout(termination);
			if (code !== 0) fail(new Error("Memory preparation stopped; inspect the checkout before retrying."));
			wake?.();
			done();
		});
	});
	for (const stream of [child.stdout, child.stderr, control]) stream?.on("error", fail);
	child.stderr!.on("data", () => fail(new Error("Native memory operation refused. If the checkout is attached, run /mem-prepare, then retry. Check for dirty checkout files. Do not remove unknown Git locks automatically. For a legacy native review lease, reopen /mem-review with its original explicit configuration.")));
	child.stdout!.on("data", (bytes: Buffer) => {
		try {
			aggregate += bytes.length;
			if (aggregate > 2 * (frameLimit + 1)) throw new Error("Oversized memory preparation output.");
			buffer = Buffer.concat([buffer, bytes]);
			let newline: number;
			while ((newline = buffer.indexOf(10)) !== -1) {
				if (newline > frameLimit || frames.length === 2) throw new Error("Unexpected memory preparation frame.");
				const value = parseDreamJSON(buffer.subarray(0, newline));
				if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid memory preparation frame.");
				frames.push(value as Record<string, unknown>);
				buffer = buffer.subarray(newline + 1);
			}
			if (buffer.length > frameLimit) throw new Error("Oversized memory preparation frame.");
			wake?.();
		} catch (error) { fail(error as Error); }
	});
	async function next(index: number, fields: string[]): Promise<Record<string, unknown>> {
		while (!frames[index] && !isClosed && !processError) await new Promise<void>((done) => { wake = done; });
		if (processError) throw processError;
		const value = frames[index];
		if (!value || Object.keys(value).sort().join("\0") !== fields.sort().join("\0")) throw new Error("Invalid memory preparation fields.");
		return value;
	}
	try {
		control.write(JSON.stringify({ repo: repository(ctx), ...(selection ? { ...selection, cwd: ctx.cwd } : {}) }) + "\n");
		if (selection) {
			const preview = await next(0, ["type", "digest", "entry"]);
			if (preview.type !== "entry" || typeof preview.digest !== "string" || !/^[a-f0-9]{64}$/.test(preview.digest)
				|| !preview.entry || typeof preview.entry !== "object") throw new Error("Invalid entry preview.");
			const entry = preview.entry as ReviewCatalog["catalog"]["entries"][number];
			if (typeof entry.expected !== "string" || typeof entry.path !== "string" || typeof entry.isMutable !== "boolean") throw new Error("Invalid entry fields.");
			const details = `${entry.path}\nReviewed: ${entry.reviewed ?? "unknown"}\nRevised: ${entry.revised ?? "unknown"}\nStored sources are unverified references.\n${entry.expected}\n${entry.limitation ?? ""}`;
			const choice = await Promise.race([chooseApprovedReview(ctx, details, entry.isMutable, previewSignal), failure]);
			const action = choice === "Confirm reviewed" && !signal.aborted ? "confirm" : choice === "Defer" ? "defer" : "back";
			control.end(JSON.stringify({ digest: preview.digest, action }) + "\n");
			const result = await next(1, ["type", "status"]);
			if (result.type !== "result" || result.status !== (action === "confirm" ? "reviewed" : "unchanged")) throw new Error("Invalid review result.");
			await Promise.race([closed, failure]);
			if (processError) throw processError;
			if (buffer.length || frames.length !== 2) throw new Error("Unexpected review output.");
			ctx.ui.notify(action === "confirm" ? "Memory review recorded. Saved session memory stays unchanged." : "Memory stays in use. Review date unchanged.", "info");
			return;
		}
		const preview = await next(0, ["type", "digest", "commit", "main", "isDetachRequired"]);
		if (preview.type !== "preview" || typeof preview.digest !== "string" || !/^[a-f0-9]{64}$/.test(preview.digest)
			|| typeof preview.commit !== "string" || !/^([a-f0-9]{40}|[a-f0-9]{64})$/.test(preview.commit)
			|| typeof preview.main !== "string" || !/^([a-f0-9]{40}|[a-f0-9]{64})$/.test(preview.main)
			|| typeof preview.isDetachRequired !== "boolean") throw new Error("Invalid checkout preview.");
		const choice = preview.isDetachRequired
			? await Promise.race([ctx.ui.select(`Detach private memory checkout at ${preview.commit}? Index and working files stay unchanged. Approved memory stays on main.`, ["Decline", "Detach private checkout"], { signal }), failure])
			: "Decline";
		const action = choice === "Detach private checkout" && !signal.aborted ? "detach" : "decline";
		control.end(JSON.stringify({ digest: preview.digest, action }) + "\n");
		const result = await next(1, ["type", "status"]);
		if (result.type !== "result" || result.status !== (action === "detach" ? "detached" : "unchanged")) throw new Error("Invalid preparation result.");
		await Promise.race([closed, failure]);
		if (processError) throw processError;
		if (buffer.length || frames.length !== 2) throw new Error("Unexpected preparation output.");
		ctx.ui.notify(action === "detach" ? "Memory checkout prepared. No memory entry changed." : "Memory checkout unchanged.", "info");
	} finally {
		previewController.abort();
		control.destroy();
		terminate();
		await closed;
	}
}
