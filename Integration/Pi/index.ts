import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { buildCommand, clearBuildResult, commandPath, commandReady } from "./command.ts";
import { registerDreamHistory } from "./dream.ts";
import { registerQueuedRuntime } from "./queued-runtime.ts";
import { filterMemoryMessages, isSnapshotOnBranch, memoryMessage, withSavedSnapshot, type MemoryScope } from "./policy.ts";

export type Render = (scope: MemoryScope, signal: AbortSignal) => Promise<string>;

export async function renderApproved(scope: MemoryScope, signal: AbortSignal): Promise<string> {
	await commandReady(signal);
	return new Promise((done, fail) => {
		execFile(
			commandPath(),
			["render", "--repo", scope.memoryRepo, "--cwd", scope.cwd],
			{ cwd: scope.cwd, timeout: 10_000, signal, encoding: "buffer", maxBuffer: 16 * 1024 * 1024 },
			(error, stdout) => {
				if (error) return fail(error);
				try {
					done(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(stdout));
				} catch (decodeError) {
					fail(decodeError);
				}
			},
		);
	});
}

function scopeOf(ctx: ExtensionContext): MemoryScope {
	return {
		sessionId: ctx.sessionManager.getSessionId(),
		cwd: ctx.cwd,
		memoryRepo: process.env.PI_CORE_MEMORIES_REPO
			? resolve(ctx.cwd, process.env.PI_CORE_MEMORIES_REPO)
			: join(homedir(), ".local", "share", "pi-core-memories"),
	};
}

export default function coreMemories(pi: ExtensionAPI, render: Render = renderApproved): void {
	registerDreamHistory(pi);
	registerQueuedRuntime(pi);
	let controller: AbortController | undefined;
	let warnedSessionId: string | undefined;

	pi.on("session_start", (_event, ctx) => { void buildCommand(ctx); });
	pi.on("session_shutdown", () => {
		controller?.abort();
		controller = undefined;
	});

	pi.on("before_agent_start", async (event, ctx) => {
		if (event.messageType === "user") clearBuildResult(ctx);
		const scope = scopeOf(ctx);
		if (isSnapshotOnBranch(ctx.sessionManager.getBranch(), scope)) return;
		controller?.abort();
		const current = new AbortController();
		controller = current;
		try {
			const markdown = await render(scope, current.signal);
			if (current.signal.aborted) return;
			return { message: memoryMessage(markdown, scope) };
		} catch {
			if (current.signal.aborted || ctx.mode !== "tui" || warnedSessionId === scope.sessionId) return;
			warnedSessionId = scope.sessionId;
			ctx.ui.notify("Core memories were not loaded. Check pi-core-memories and the approved store.", "warning");
		} finally {
			if (controller === current) controller = undefined;
		}
	});

	pi.on("context", (event, ctx) => {
		const scope = scopeOf(ctx);
		return { messages: withSavedSnapshot(filterMemoryMessages(event.messages, scope), ctx.sessionManager.getBranch(), scope) };
	});
}
