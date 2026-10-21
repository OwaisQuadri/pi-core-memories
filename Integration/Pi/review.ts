import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { lstat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { Key, matchesKey, ScrollView, SelectList, Text } from "@earendil-works/pi-tui";
import type { Component, TUI } from "@earendil-works/pi-tui";
import { commandPath, commandReady } from "./command.ts";
import { dreamRoots, escapeDreamDisplay, isMemoryPath, parseDreamJSON, workerEnvironment } from "./dream.ts";
import type { DreamRoots } from "./dream.ts";

const maximumFrameBytes = 8 * 1_048_576;
const entryType = "core-memory-entry-review";
type Disposition = "pending" | "deferred" | "rejected" | "approved" | "blocked";
type Candidate = { candidateID: string; path: string; operation: string; disposition: Disposition; limitation: string | null; frozenLimitations: string[] };
type Header = { version: 1; invocationID: string };
type Queue = Header & { type: "queue"; candidates: Candidate[] };
type Preview = Header & { type: "preview"; candidateID: string; sequence: string; digest: string; isDetachRequired: boolean; checkoutCommit: string; details: string };
type Operation = Header & { type: "operation"; status: "approved" | "detached" | "rejected" | "deferred" | "blocked"; candidateID: string; commit: string | null; auditRef: string | null; reason: string | null };
type Final = Header & { type: "final"; status: "completed" | "blocked" | "failed"; reason: string | null };
type Frame = Queue | Preview | Operation | Final;
type Start = Header & { type: "start"; roots: DreamRoots; reviewState: string };

export function escapeReviewDetails(details: string): string {
	return details.split("\n").map(escapeDreamDisplay).join("\n");
}

function failure(): never { throw new Error("Private memory review transport failed."); }
function object(value: unknown): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) return failure();
	return value as Record<string, unknown>;
}
function fields(value: Record<string, unknown>, keys: string[]): void {
	if (Object.keys(value).sort().join("\0") !== keys.sort().join("\0")) failure();
}
function text(value: unknown): string {
	if (typeof value !== "string" || Buffer.byteLength(value) > maximumFrameBytes || value.includes("\0")) return failure();
	return value;
}
function hash(value: unknown): void { if (!/^[a-f0-9]{64}$/.test(text(value))) failure(); }
function commit(value: unknown): void { if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(text(value))) failure(); }
function nullable(value: unknown): void { if (value !== null) text(value); }

export function parseReviewFrame(bytes: Uint8Array, invocationID: string): Frame {
	if (bytes.length > maximumFrameBytes) failure();
	const value = object(parseDreamJSON(bytes));
	if (value.version !== 1 || value.invocationID !== invocationID) failure();
	const header = ["version", "type", "invocationID"];
	switch (value.type) {
		case "queue":
			fields(value, [...header, "candidates"]);
			if (!Array.isArray(value.candidates) || value.candidates.length > 32768) failure();
			for (const row of value.candidates) {
				const item = object(row);
				fields(item, ["candidateID", "path", "operation", "disposition", "limitation", "frozenLimitations"]);
				hash(item.candidateID);
				if (!isMemoryPath(text(item.path)) || !["add", "update"].includes(text(item.operation))) failure();
				if (!["pending", "deferred", "rejected", "approved", "blocked"].includes(text(item.disposition))) failure();
				nullable(item.limitation);
				if (!Array.isArray(item.frozenLimitations) || item.frozenLimitations.length > 4096) failure();
				item.frozenLimitations.forEach(text);
			}
			break;
		case "preview":
			fields(value, [...header, "candidateID", "sequence", "digest", "isDetachRequired", "checkoutCommit", "details"]);
			hash(value.candidateID); hash(value.digest); commit(value.checkoutCommit); text(value.details);
			if (typeof value.isDetachRequired !== "boolean" || !/^[1-9][0-9]{0,19}$/.test(text(value.sequence))) failure();
			break;
		case "operation":
			fields(value, [...header, "status", "candidateID", "commit", "auditRef", "reason"]);
			hash(value.candidateID); nullable(value.reason); nullable(value.auditRef);
			if (value.commit !== null) commit(value.commit);
			if (!["approved", "detached", "rejected", "deferred", "blocked"].includes(text(value.status))) failure();
			if (value.status === "approved" && (value.commit === null || !/^refs\/memory-review\/approvals\/[a-f0-9]{64}$/.test(text(value.auditRef)))) failure();
			break;
		case "final":
			fields(value, [...header, "status", "reason"]);
			if (!["completed", "blocked", "failed"].includes(text(value.status))) failure();
			nullable(value.reason);
			break;
		default: failure();
	}
	return value as Frame;
}

class ReviewWorker {
	private readonly child;
	private readonly control: Duplex;
	private buffer = Buffer.alloc(0);
	private aggregate = 0;
	private isFinal = false;
	private isClosing = false;
	private isFailed = false;
	private outstanding: Preview | undefined;
	readonly completion: Promise<void>;
	onFrame: (frame: Frame) => void = () => {};
	onFailure: () => void = () => {};

	private readonly start: Start;

	constructor(start: Start) {
		this.start = start;
		this.child = spawn(commandPath(), ["memory-review-worker"], { stdio: ["pipe", "pipe", "pipe", "pipe"], env: workerEnvironment() });
		this.control = this.child.stdio[3] as Duplex;
		this.completion = new Promise((resolve) => {
			this.child.on("error", () => this.fail());
			this.child.on("close", (code, signal) => {
				if (!this.isFinal || code !== 0 || signal !== null || this.buffer.length) this.fail();
				resolve();
			});
		});
		for (const stream of [this.child.stdin, this.child.stdout, this.child.stderr, this.control]) stream?.on("error", () => this.fail());
		this.child.stderr!.on("data", (data: Buffer) => { if (data.length) this.fail(); });
		this.child.stdout!.on("data", (data: Buffer) => {
			try {
				this.aggregate += data.length;
				if (this.aggregate > 64 * maximumFrameBytes) failure();
				this.buffer = Buffer.concat([this.buffer, data]);
				let newline: number;
				while ((newline = this.buffer.indexOf(10)) !== -1) {
					if (this.isFinal) failure();
					const frame = parseReviewFrame(this.buffer.subarray(0, newline), start.invocationID);
					this.buffer = this.buffer.subarray(newline + 1);
					if (frame.type === "preview") {
						if (this.outstanding) failure();
						this.outstanding = frame;
					} else this.outstanding = undefined;
					if (frame.type === "final") this.isFinal = true;
					this.onFrame(frame);
				}
				if (this.buffer.length > maximumFrameBytes) failure();
			} catch { this.fail(); }
		});
		this.child.stdin!.write(JSON.stringify(start) + "\n");
	}

	request(type: "list" | "preview" | "finish", candidateID?: string): void {
		if (this.isFailed || this.isClosing || this.isFinal) return;
		this.outstanding = undefined;
		this.child.stdin!.write(JSON.stringify({ version: 1, type, invocationID: this.start.invocationID, ...(candidateID ? { candidateID } : {}) }) + "\n");
	}

	choose(preview: Preview, action: "approve" | "detach" | "reject" | "defer"): void {
		if (this.isFailed || this.isClosing || this.outstanding !== preview) return this.fail();
		this.outstanding = undefined;
		this.control.write(JSON.stringify({ version: 1, type: "choice", invocationID: this.start.invocationID, sequence: preview.sequence, candidateID: preview.candidateID, digest: preview.digest, action }) + "\n");
	}

	cancel(): void {
		if (this.isClosing) return;
		this.isClosing = true;
		this.child.stdin!.end(JSON.stringify({ version: 1, type: "cancel", invocationID: this.start.invocationID }) + "\n");
		this.control.end();
		const timer = setTimeout(() => this.child.kill("SIGKILL"), 1500);
		void this.completion.finally(() => clearTimeout(timer));
	}

	private fail(): void {
		if (this.isFailed) return;
		this.isFailed = true;
		this.onFailure();
		this.cancel();
	}
}

class ReviewScreen implements Component {
	private candidates: Candidate[] = [];
	private filter: "active" | Disposition | "all" = "active";
	private menu: SelectList;
	private scroll: ScrollView | undefined;
	private preview: Preview | undefined;
	private isBusy = true;
	private status = "Loading memory review";
	private isInputAction = false;
	private pendingCandidateID: string | undefined;
	private isAuditVisible = false;

	private readonly tui: TUI;
	private readonly theme: Theme;
	private readonly worker: ReviewWorker;
	private readonly done: () => void;
	private readonly record: (operation: Operation) => void;

	constructor(tui: TUI, theme: Theme, worker: ReviewWorker, done: () => void, record: (operation: Operation) => void) {
		this.tui = tui;
		this.theme = theme;
		this.worker = worker;
		this.done = done;
		this.record = record;
		this.menu = this.list([]);
		worker.onFrame = (frame) => this.receive(frame);
		worker.onFailure = () => { this.status = "Private memory review failed"; this.isBusy = false; this.menu = this.list([{ value: "close", label: "Close" }]); this.tui.requestRender(); };
	}

	private list(items: { value: string; label: string }[]): SelectList {
		const list = new SelectList(items, 10, {
			selectedPrefix: (value) => this.theme.fg("accent", value), selectedText: (value) => this.theme.fg("accent", value),
			description: (value) => this.theme.fg("muted", value), scrollInfo: (value) => this.theme.fg("muted", value), noMatch: (value) => this.theme.fg("muted", value),
		});
		list.onSelect = (item) => { if (this.isInputAction) this.select(item.value); };
		return list;
	}

	private queue(): void {
		this.preview = undefined;
		this.scroll = undefined;
		const items = this.candidates.filter((item) => this.filter === "all" || (this.filter === "active" ? item.disposition === "pending" || item.disposition === "deferred" : item.disposition === this.filter));
		this.menu = this.list(items.map((item) => ({ value: item.candidateID, label: `${item.disposition} · ${item.operation} · ${item.path} · ${item.candidateID.slice(0, 12)}` })));
	}

	private previewText(): void {
		if (!this.preview) return;
		const details = this.isAuditVisible ? this.preview.details : this.preview.details.split(`\nAudit\nCandidate: ${this.preview.candidateID}\n`)[0]!;
		this.scroll = new ScrollView(new Text(escapeReviewDetails(details), 0, 0), { scrollbar: "always" });
	}

	private receive(frame: Frame): void {
		if (frame.type === "queue") { this.candidates = frame.candidates; this.isBusy = false; if (this.status === "Loading memory review") this.status = "Review queue"; this.queue(); }
		if (frame.type === "preview") {
			this.preview = frame;
			if (frame.isDetachRequired) {
				this.status = "Preparing the memory checkout (one time)";
				this.pendingCandidateID = frame.candidateID;
				this.preview = undefined;
				this.worker.choose(frame, "detach");
			} else {
				this.isBusy = false;
				this.status = "Proposed memory";
				this.isAuditVisible = false;
				this.previewText();
				this.menu = this.list([{ value: "back", label: "Back to list" }, { value: "approve", label: "Approve: save to memory" }, { value: "reject", label: "Reject" }, { value: "defer", label: "Defer: decide later" }]);
			}
		}
		if (frame.type === "operation") {
			if (frame.status !== "detached") this.pendingCandidateID = undefined;
			this.preview = undefined;
			this.status = frame.reason ? `${frame.status}: ${escapeDreamDisplay(frame.reason)}` : `${frame.status}: ${frame.candidateID.slice(0, 12)}`;
			this.record(frame);
		}
		if (frame.type === "queue" && this.pendingCandidateID) {
			const candidateID = this.pendingCandidateID;
			this.pendingCandidateID = undefined;
			if (this.candidates.some((item) => item.candidateID === candidateID && (item.disposition === "pending" || item.disposition === "deferred"))) { this.isBusy = true; this.worker.request("preview", candidateID); }
		}
		if (frame.type === "final") {
			this.isBusy = false;
			if (frame.status === "completed") this.done();
			else { this.status = escapeDreamDisplay(frame.reason ?? "Memory review stopped"); this.menu = this.list([{ value: "close", label: "Close" }]); }
		}
		this.tui.requestRender();
	}

	private select(value: string): void {
		if (value === "close") { this.done(); return; }
		if (this.isBusy) return;
		const preview = this.preview;
		if (preview) {
			if (value === "back") { this.isBusy = true; this.preview = undefined; this.scroll = undefined; this.worker.request("list"); }
			else if (value === "approve" || value === "reject" || value === "defer") {
				this.isBusy = true; this.preview = undefined; this.worker.choose(preview, value);
			}
		} else {
			const candidate = this.candidates.find((item) => item.candidateID === value);
			if (!candidate) return;
			if (candidate.disposition === "blocked" || candidate.disposition === "approved" || candidate.disposition === "rejected") {
				this.status = escapeDreamDisplay(candidate.limitation ?? candidate.disposition); return;
			}
			this.isBusy = true; this.worker.request("preview", candidate.candidateID);
		}
	}

	handleInput(data: string): void {
		if (matchesKey(data, Key.escape)) { this.worker.cancel(); this.done(); return; }
		if (this.isBusy) return;
		if (this.preview && data === "d") {
			this.isAuditVisible = !this.isAuditVisible;
			this.previewText(); this.tui.requestRender(); return;
		}
		const isPageBack = matchesKey(data, Key.pageUp) || matchesKey(data, "ctrl+b");
		const isPageForward = matchesKey(data, Key.pageDown) || matchesKey(data, "ctrl+f");
		if (this.scroll && (isPageBack || isPageForward)) {
			this.scroll.scrollBy(isPageBack ? -10 : 10); this.tui.requestRender(); return;
		}
		if (!this.preview && data === "f") {
			const filters = ["active", "pending", "deferred", "rejected", "approved", "blocked", "all"] as const;
			this.filter = filters[(filters.indexOf(this.filter) + 1) % filters.length]!; this.queue(); this.tui.requestRender(); return;
		}
		this.isInputAction = true;
		try { this.menu.handleInput(data); } finally { this.isInputAction = false; }
		this.tui.requestRender();
	}

	render(width: number): string[] {
		const heading = new Text(this.theme.fg("accent", "Memory review"), 0, 0).render(width);
		const status = new Text(this.status, 0, 0).render(width);
		const menu = this.menu.render(width);
		if (this.scroll) {
			const height = Math.max(3, Math.min(18, this.tui.terminal.rows - menu.length - heading.length - status.length - 4));
			const contentHeight = this.scroll.render(width).length;
			this.scroll.updateLayout(contentHeight, height, () => this.tui.requestRender());
			return [...heading, ...status, ...this.scroll.render(width).slice(this.scroll.scrollTop, this.scroll.scrollTop + height), ...menu, ...new Text("↑/↓: choose · Enter: confirm · Ctrl+B/Ctrl+F: scroll · d: audit · Escape: close", 0, 0).render(width)];
		}
		return [...heading, ...status, ...new Text(`Enter: open an entry · f: filter (${this.filter}) · Escape: close`, 0, 0).render(width), ...menu];
	}

	invalidate(): void { this.menu.invalidate(); this.scroll?.invalidate(); }
}

export function registerReview(pi: ExtensionAPI): () => Promise<void> {
	let worker: ReviewWorker | undefined;
	const currentWorker = (): ReviewWorker | undefined => worker;
	let dismiss: (() => void) | undefined;
	let isStarting = false;
	let isShuttingDown = false;
	pi.registerEntryRenderer<Operation>(entryType, (entry) => entry.data ? new Text(escapeReviewDetails(`Memory review: ${entry.data.status}\nCandidate: ${entry.data.candidateID}\nCommit: ${entry.data.commit ?? "none"}\nAudit: ${entry.data.auditRef ?? "none"}${entry.data.reason ? `\nReason: ${entry.data.reason}` : ""}`), 0, 0) : undefined);
	pi.registerCommand("mem-review", {
		description: "Review one proposed memory entry at a time",
		handler: async (args, ctx) => {
			if (args.trim() || ctx.mode !== "tui") { ctx.ui.notify("Use /mem-review without arguments in terminal mode.", "error"); return; }
			if (worker || isStarting || isShuttingDown) { ctx.ui.notify("Memory review is busy.", "warning"); return; }
			isStarting = true;
			try {
				await ctx.waitForIdle();
				if (isShuttingDown) return;
				const home = homedir();
				const roots = await dreamRoots(getAgentDir(), ctx.cwd, home);
				try { await lstat(join(roots.state, "root.json")); }
				catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") { ctx.ui.notify("Run /dream first.", "info"); return; } throw error; }
				await commandReady();
				if (isShuttingDown) return;
				await ctx.ui.custom<void>((tui, theme, _keys, done) => {
					const current = new ReviewWorker({ version: 1, type: "start", invocationID: randomBytes(16).toString("hex"), roots, reviewState: join(home, ".local", "state", "pi-core-memories-review") });
					worker = current;
					dismiss = () => done();
					return new ReviewScreen(tui, theme, current, () => done(), (operation) => pi.appendEntry(entryType, operation));
				});
			} catch { ctx.ui.notify("Private memory review failed.", "error"); }
			finally { const active = currentWorker(); active?.cancel(); await active?.completion; worker = undefined; dismiss = undefined; isStarting = false; }
		},
	});
	return async () => { isShuttingDown = true; dismiss?.(); worker?.cancel(); await worker?.completion; };
}
