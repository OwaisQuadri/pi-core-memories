import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { buildCommand, clearBuildResult, commandPath, commandReady, isCommandMissing } from "./command.ts";
import { escapeDreamDisplay, registerDream } from "./dream.ts";
import { registerReview } from "./review.ts";
import { registerQueuedRuntime } from "./queued-runtime.ts";
import { registerMemoryManagement, reviewCatalog } from "./management.ts";
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

export default function coreMemories(pi: ExtensionAPI, render: Render = renderApproved, catalog: typeof reviewCatalog = reviewCatalog): void {
	const abortDream = registerDream(pi);
	const abortReview = registerReview(pi);
	const abortManagement = registerMemoryManagement(pi);
	registerQueuedRuntime(pi);
	let controller: AbortController | undefined;
	let warnedSessionId: string | undefined;
	let reminder: AbortController | undefined;
	let reminderSessionId: string | undefined;

	pi.on("session_start", async (_event, ctx) => {
		void buildCommand(ctx);
		if (ctx.mode !== "tui" || !ctx.hasUI || isCommandMissing()) return;
		const scope = scopeOf(ctx);
		if (reminder && reminderSessionId === scope.sessionId) return;
		reminder?.abort();
		if (ctx.sessionManager.getEntries().some((entry) => entry.type === "custom" && entry.customType === "core-memory-review-reminder"
			&& (entry.data as { sessionId?: string } | undefined)?.sessionId === scope.sessionId)) return;
		const current = new AbortController();
		reminder = current;
		reminderSessionId = scope.sessionId;
		try {
			const result = await catalog(scope.memoryRepo, scope.cwd, current.signal);
			if (current.signal.aborted) return;
			pi.appendEntry("core-memory-review-reminder", { sessionId: scope.sessionId });
			if (!result.due.length) return;
			const entries = result.due.slice(0, 3).map((index) => {
				const entry = result.catalog.entries[index];
				const preview = escapeDreamDisplay(entry.expected.slice(0, 120)).slice(0, 120);
				return `${index + 1}. ${escapeDreamDisplay(entry.path.slice(0, 240))}: ${preview}`.slice(0, 240);
			});
			const omitted = result.due.length - entries.length;
			const remaining = omitted ? `\n${omitted} more not shown.` : "";
			ctx.ui.notify(`${result.due.length} approved memories need review (30 days or unknown review date). They stay in use. Run /mem-rereview.\n${entries.join("\n")}${remaining}`, "warning");
		} catch {
			if (!current.signal.aborted) {
				pi.appendEntry("core-memory-review-reminder", { sessionId: scope.sessionId });
				ctx.ui.notify("Memory review dates could not be checked. Memories stay in use. Run /mem-rereview to check.", "warning");
			}
		} finally {
			if (reminder === current) reminder = undefined;
		}
	});

	pi.on("session_shutdown", () => {
		controller?.abort();
		reminder?.abort();
		controller = undefined;
		return Promise.all([abortDream(), abortReview(), abortManagement()]).then(() => {});
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
