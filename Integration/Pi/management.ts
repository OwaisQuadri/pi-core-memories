import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { commandPath, commandReady } from "./command.ts";
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
	await commandReady(signal);
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
const permission = "Use only for an explicit user-requested change to the exact displayed entry. Require explicit approval of the proposal shown in conversation before writing. To continue after the user's later memory-specific reply, call this same tool with unchanged arguments, including reason. The host supplies the original reply; never place approval in reason or another field. Changed arguments require a new preview and a later reply. Never use for inferred preferences or background consolidation. Pending findings stay in the shared conversation queue; this tool cannot bypass queue authority. If checkout preparation is blocked, explain it in conversation. Do not prescribe a command or a separate review screen. Changes load in a new session, not this session's saved snapshot.";

export type MemoryChange = (tool: string, request: Record<string, unknown>, signal: AbortSignal | undefined, ctx: ExtensionToolContext) => Promise<unknown>;

export function registerMemoryManagement(pi: ExtensionAPI, change: MemoryChange): void {
	for (const tool of [
		{ name: "memory_list", operation: "list", description: "List the bounded committed approved memory catalog with exact bases, locators, bytes, identities and dates. Excludes pending dream candidates.", parameters: Type.Object({}, { additionalProperties: false }) },
		{ name: "memory_get", operation: "get", description: "Get one approved entry at the exact listed base, locator and expected bytes. Does not read dream candidates.", parameters: Type.Object(target, { additionalProperties: false }) },
		{ name: "memory_add", operation: "add", description: `Add one approved memory entry. ${permission}`, parameters: Type.Object({ base: target.base, path: Type.String({ description: "MEMORY.md, projects/<project key>.md, devices/<device key>/MEMORY.md, or devices/<device key>/projects/<project key>.md. Obtain exact 64 lowercase hex keys from the catalog. Never guess them." }), replacement, reason }, { additionalProperties: false }) },
		{ name: "memory_update", operation: "update", description: `Update one exact approved memory entry, preserving identity and source annotations. ${permission}`, parameters: Type.Object({ ...target, replacement, reason }, { additionalProperties: false }) },
		{ name: "memory_delete", operation: "delete", description: `Delete only the exact approved entry, retaining its previous bytes and references in the direct-change audit. ${permission}`, parameters: Type.Object({ ...target, reason }, { additionalProperties: false }) },
	]) {
		pi.registerTool({
			name: tool.name, label: tool.name, description: tool.description, parameters: tool.parameters,
			executionMode: "sequential",
			async execute(_id, params, signal, _update, ctx) {
				const request = { ...params, operation: tool.operation };
				const result = tool.operation === "list" || tool.operation === "get"
					? await manageMemory(repository(ctx), ctx.cwd, request, signal)
					: await change(tool.name, request, signal, ctx);
				const text = JSON.stringify(result).replace(/[\u202a-\u202e\u2066-\u2069]/g, (value) => `\\u${value.charCodeAt(0).toString(16).padStart(4, "0")}`);
				return { content: [{ type: "text", text }], details: result };
			},
		});
	}
}
