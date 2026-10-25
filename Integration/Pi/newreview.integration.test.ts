import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { constants, openSync, closeSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import type { Socket } from "node:net";
import { join, resolve } from "node:path";
import type { Duplex } from "node:stream";
import { test } from "node:test";
import type { TestContext } from "node:test";
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";

import { sdkURL } from "./test/host.ts";
import { protectDreamSources } from "./source-protection.ts";
import { sourceProtectionFixture } from "./test/source-protection.ts";
const dream = await import("./dream.ts");
const review = await import("./review.ts");
const sdk = await import(sdkURL) as typeof import("@earendil-works/pi-coding-agent");
const binary = process.env.PI_CORE_MEMORIES_BIN ?? process.env.PI_CORE_MEMORIES_EXECUTABLE;
assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the verified release command");

async function fixture(t: TestContext) {
	const root = await mkdtemp("/private/tmp/pi-entry-review-");
	const home = join(root, "home"); const agent = join(home, "agent"); const repo = join(root, "memory"); const bin = join(root, "bin");
	const previous = Object.fromEntries(["HOME", "PI_CORE_MEMORIES_EXECUTABLE", "PI_CORE_MEMORIES_REPO", "PI_CODING_AGENT_DIR"].map((name) => [name, process.env[name]]));
	const previousFetch = globalThis.fetch;
	globalThis.fetch = async () => assert.fail("No network calls");
	t.after(async () => {
		globalThis.fetch = previousFetch;
		for (const [name, value] of Object.entries(previous)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
		await rm(root, { recursive: true, force: true });
	});
	await mkdir(agent, { recursive: true });
	process.env.HOME = home; process.env.PI_CORE_MEMORIES_EXECUTABLE = resolve(binary!); process.env.PI_CODING_AGENT_DIR = agent; process.env.PI_CORE_MEMORIES_REPO = repo;
	execFileSync(binary!, ["init", "--repo", repo]);
	const sessions = join(agent, "sessions", "fixture"); await mkdir(sessions, { recursive: true });
	await writeFile(join(sessions, "fixture.jsonl"), [
		{ type: "session", version: 3, id: "fixture", timestamp: "1999-01-01T00:00:00.000Z", cwd: root },
		{ type: "message", id: "entry", parentId: null, timestamp: "1999-01-01T00:00:00.000Z", message: { role: "user", content: "Keep A café 🌱 and B.\u001b[31m", timestamp: 0 } },
	].map((value) => JSON.stringify(value) + "\n").join(""));
	const roots = await dream.dreamRoots(agent, root);
	const report = await dream.runDreamWorker({ version: 1, type: "start", invocationID: "fixture", roots, selection: { provider: "fixture", modelID: "selected", thinkingLevel: "off" }, resume: "inspectOrContinue", batchTextBytes: 262_144 }, async (request) => {
		const source = JSON.parse(request.messages[0].text).primaryEvidence[0].source;
		return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: ["Keep A café 🌱.", "Keep B."].map((text) => ({ kind: "add", scope: { kind: "global" }, text, sources: [source], contradictions: [], reason: "Keep separate preferences." })) });
	}, new AbortController().signal, undefined, (value, signal) => protectDreamSources(sourceProtectionFixture(), "fixture", value, signal));
	assert.equal(report.status, "completed");
	const git = (...args: string[]) => execFileSync("/usr/bin/git", ["-C", repo, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	return { root, roots, repo, home, git, report, start: { version: 1, type: "start", invocationID: "review-fixture", roots, reviewState: join(home, ".local", "state", "pi-core-memories-review") } };
}

async function waitFor(check: () => boolean, diagnostics: () => unknown = () => undefined): Promise<void> {
	const deadline = Date.now() + 7000;
	while (!check()) {
		if (Date.now() >= deadline) assert.fail(`UI state deadline\n${JSON.stringify(diagnostics())?.slice(0, 8192) ?? ""}`);
		await new Promise((done) => setTimeout(done, 10));
	}
}

async function nativeCommand(f: Awaited<ReturnType<typeof fixture>>) {
	sdk.initTheme("dark", false);
	let component: Component | undefined;
	let shutdown: () => Promise<void> = async () => {};
	const runtime = await sdk.ModelRuntime.create({ authPath: join(f.home, "offline-auth.json"), modelsPath: null, modelsStorePath: join(f.home, "offline-models.json"), allowModelNetwork: false, refreshOnCreate: false });
	runtime.streamSimple = () => assert.fail("Review must not call providers");
	const settingsManager = sdk.SettingsManager.inMemory({ retry: { enabled: false }, cacheWarming: "off", compaction: { enabled: false } });
	const agentDir = join(f.home, "agent");
	const loader = new sdk.DefaultResourceLoader({ cwd: f.root, agentDir, settingsManager, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [(pi: ExtensionAPI) => { shutdown = review.registerReview(pi); }] });
	await loader.reload();
	const manager = sdk.SessionManager.inMemory(f.root);
	const { session } = await sdk.createAgentSession({ cwd: f.root, agentDir, resourceLoader: loader, modelRuntime: runtime, settingsManager, sessionManager: manager, tools: [] });
	await session.bindExtensions({ mode: "tui", onError: (error) => assert.fail(error.error), uiContext: {
		notify: (message: string) => assert.fail(message),
		custom: (factory: (...args: unknown[]) => unknown) => new Promise<void>((done) => {
			component = factory({ terminal: { rows: 32 }, requestRender: () => {} }, { fg: (_name: string, value: string) => value }, {}, done) as Component;
		}),
	} as unknown as ExtensionUIContext });
	const completion = session.prompt("/mem-review");
	const screen = () => { assert.ok(component); return component.render(72).join("\n"); };
	const key = (value: string) => { assert.ok(component?.handleInput); component.handleInput(value); };
	await waitFor(() => !!component && /(?:pending|deferred) ·/.test(screen()));
	return { screen, key, get entries() { return manager.getBranch().filter((entry) => entry.type === "custom" && entry.customType === "core-memory-entry-review").map((entry) => entry.type === "custom" ? entry.data : undefined); }, completion, shutdown: async () => { await shutdown(); session.dispose(); }, component: () => component! };
}

test("native SDK command dispatch detaches on its own, approves one sibling only, and retains pending sibling after restart", { timeout: 30000 }, async (t) => {
	const f = await fixture(t);
	const beforeHead = f.git("rev-parse", "HEAD"); const beforeMain = f.git("rev-parse", "main");
	const beforeIndex = await readFile(join(f.repo, ".git", "index")); const beforeFile = await readFile(join(f.repo, "MEMORY.md"));
	const ui = await nativeCommand(f);
	assert.equal(f.git("symbolic-ref", "HEAD"), "refs/heads/main");
	ui.key("\r"); await waitFor(() => ui.screen().includes("Approve: save to memory"));
	assert.ok(!ui.screen().includes("Detach"), "The one-time checkout step never asks the human");
	assert.equal(f.git("rev-parse", "HEAD"), beforeHead); assert.equal(f.git("rev-parse", "main"), beforeMain);
	assert.throws(() => f.git("symbolic-ref", "HEAD"));
	assert.ok(ui.screen().includes("Add to MEMORY.md:"), "The proposed entry leads the preview");
	assert.ok(!ui.screen().includes("[memory-id:"), "Storage annotations stay in the audit tail");
	assert.ok(!ui.screen().includes("Candidate:"), "Audit identifiers are hidden by default");
	ui.key("d");
	ui.key("\u0006"); ui.screen(); ui.key("\u0006");
	assert.ok(ui.screen().includes("Audit") || ui.screen().includes("Exact final new bytes:"), "Portable paging reaches the audit tail");
	ui.key("\u0002"); ui.screen(); ui.key("\u0002");
	assert.ok(ui.screen().includes("Add to MEMORY.md:"), "Portable reverse paging returns to the entry header");
	ui.key("d");
	assert.ok(!ui.screen().includes("Candidate:"), "The audit view can be closed");
	for (const line of ui.component().render(24)) assert.ok(!line.includes("\u001b[31m"), "Source controls escaped");
	ui.key("\r"); await waitFor(() => ui.screen().includes("pending ·"));
	assert.equal(f.git("rev-parse", "main"), beforeMain, "Default Enter is Back, not approve");
	ui.key("\r"); await waitFor(() => ui.screen().includes("Approve: save to memory"));
	ui.key("\u001b[B"); ui.key("\r"); await waitFor(() => ui.entries.some((entry) => (entry as { status: string }).status === "approved") && ui.screen().includes("pending ·"));
	const firstMain = f.git("rev-parse", "main"); assert.notEqual(firstMain, beforeMain);
	assert.equal((f.git("show", "main:MEMORY.md").match(/memory-id:/g) ?? []).length, 1);
	ui.key("\u001b"); await ui.completion; await ui.shutdown();
	const reopened = await nativeCommand(f);
	reopened.key("\r"); await waitFor(() => reopened.screen().includes("Approve: save to memory"));
	reopened.key("\u001b[B"); reopened.key("\r"); await waitFor(() => reopened.entries.length === 1);
	assert.notEqual(f.git("rev-parse", "main"), firstMain);
	assert.equal((f.git("show", "main:MEMORY.md").match(/memory-id:/g) ?? []).length, 2);
	reopened.key("\u001b"); await reopened.completion; await reopened.shutdown();
	assert.equal(f.git("rev-parse", "HEAD"), beforeHead); assert.deepEqual(await readFile(join(f.repo, ".git", "index")), beforeIndex); assert.deepEqual(await readFile(join(f.repo, "MEMORY.md")), beforeFile);
});

function wire(start: Record<string, unknown>) {
	const child = spawn(binary!, ["memory-review-worker"], { stdio: ["pipe", "pipe", "pipe", "pipe"], env: dream.workerEnvironment() });
	let buffer = ""; const frames: Record<string, unknown>[] = [];
	child.stdout!.on("data", (data: Buffer) => { buffer += data.toString("utf8"); let newline: number; while ((newline = buffer.indexOf("\n")) !== -1) { frames.push(JSON.parse(buffer.slice(0, newline))); buffer = buffer.slice(newline + 1); } });
	const completion = new Promise<number | null>((done) => child.on("close", done));
	const send = (value: unknown, isControl = false) => (isControl ? child.stdio[3] as Duplex : child.stdin!).write(JSON.stringify(value) + "\n");
	send(start);
	return { child, frames, send, completion };
}

for (const attack of ["stdinApprove", "unsolicited", "stale", "duplicate", "unknown", "duplicateKeys", "invalidUTF8", "overLimit", "controlEOF", "stdinEOF"] as const) test(`private worker refuses ${attack} without publishing or detaching`, { timeout: 12000 }, async (t) => {
	const f = await fixture(t); const main = f.git("rev-parse", "main");
	const w = wire(f.start); t.after(() => { if (w.child.exitCode === null) w.child.kill("SIGKILL"); });
	await waitFor(() => {
		const final = w.frames.find((frame) => frame.type === "final");
		assert.equal(final, undefined, `Worker failed before queue: ${final?.reason ?? "unknown"}`);
		assert.equal(w.child.exitCode, null, "Worker exited before queue");
		return w.frames.some((frame) => frame.type === "queue");
	});
	const queue = w.frames[0].candidates as { candidateID: string }[];
	const id = queue[0].candidateID;
	const choice = { version: 1, type: "choice", invocationID: f.start.invocationID, sequence: "1", candidateID: id, digest: "a".repeat(64), action: "approve" };
	if (attack === "stdinApprove") w.send(choice);
	else if (attack === "unsolicited") w.send(choice, true);
	else if (attack === "controlEOF") (w.child.stdio[3] as Duplex).end();
	else if (attack === "stdinEOF") w.child.stdin!.end();
	else if (attack === "duplicateKeys") (w.child.stdio[3] as Duplex).write('{"version":1,"version":1}\n');
	else if (attack === "invalidUTF8") (w.child.stdio[3] as Duplex).write(Buffer.from([0xc0, 0x80, 10]));
	else if (attack === "overLimit") (w.child.stdio[3] as Duplex).write("x".repeat(65_536) + "\n");
	else {
		w.send({ version: 1, type: "preview", invocationID: f.start.invocationID, candidateID: id });
		await waitFor(() => w.frames.some((frame) => frame.type === "preview"));
		const preview = w.frames.find((frame) => frame.type === "preview")!;
		const valid = { ...choice, sequence: preview.sequence, digest: preview.digest, action: "reject" };
		if (attack === "stale") w.send({ ...valid, digest: "f".repeat(64) }, true);
		else if (attack === "unknown") w.send({ ...valid, humanApproved: true }, true);
		else { const bytes = JSON.stringify(valid) + "\n"; (w.child.stdio[3] as Duplex).write(bytes + bytes); }
	}
	assert.equal(await w.completion, 1); assert.equal(f.git("rev-parse", "main"), main); assert.equal(f.git("symbolic-ref", "HEAD"), "refs/heads/main");
});

test("native reject and defer persist without approval, and session shutdown reaps the worker", { timeout: 20000 }, async (t) => {
	const f = await fixture(t); const before = f.git("rev-parse", "main");
	const ui = await nativeCommand(f);
	t.after(() => ui.shutdown());
	ui.key("\r"); await waitFor(() => ui.screen().includes("Approve: save to memory"), () => ({ worker: f.report, screen: ui.screen(), entries: ui.entries }));
	ui.key("\u001b[B"); ui.key("\u001b[B"); ui.key("\r"); await waitFor(() => ui.screen().includes("rejected:") && ui.screen().includes("pending ·"));
	ui.key("\r"); await waitFor(() => ui.screen().includes("Approve: save to memory"));
	for (let index = 0; index < 3; index++) ui.key("\u001b[B");
	ui.key("\r"); await waitFor(() => ui.screen().includes("deferred ·"));
	await ui.shutdown(); await ui.completion;
	const reopened = await nativeCommand(f); assert.ok(reopened.screen().includes("deferred ·"));
	for (let index = 0; index < 3; index++) reopened.key("f");
	assert.ok(reopened.screen().includes("rejected ·"));
	reopened.key("\u001b"); await reopened.completion; await reopened.shutdown();
	assert.equal(f.git("rev-parse", "main"), before); assert.throws(() => f.git("symbolic-ref", "HEAD"), "Reject and defer still complete the one-time checkout step");
});

for (const endpoint of ["regularFile", "foreignOwner", "namedFIFO", "namedUnix", "tcp", "listener"] as const) test(`private worker refuses inherited ${endpoint} endpoint`, { timeout: 10000 }, async (t) => {
	const root = await mkdtemp("/private/tmp/pi-review-endpoint-");
	t.after(() => rm(root, { recursive: true, force: true }));
	let descriptor: number | Socket;
	if (endpoint === "regularFile" || endpoint === "foreignOwner" || endpoint === "namedFIFO") {
		let path = join(root, "control");
		if (endpoint === "foreignOwner") path = "/dev/null";
		else if (endpoint === "namedFIFO") execFileSync("/usr/bin/mkfifo", [path]);
		else await writeFile(path, "");
		descriptor = openSync(path, constants.O_RDWR);
		t.after(() => closeSync(descriptor as number));
	} else {
		const server = createServer(); const sockets: Socket[] = [];
		server.on("connection", (socket) => sockets.push(socket));
		if (endpoint === "tcp") await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
		else await new Promise<void>((done) => server.listen(join(root, "socket"), done));
		t.after(async () => { for (const socket of sockets) socket.destroy(); await new Promise<void>((done) => server.close(() => done())); });
		if (endpoint === "listener") {
			const handle = server as unknown as { _handle: { fd: number } };
			descriptor = handle._handle.fd;
		} else {
			const address = server.address();
			const socket = typeof address === "string" ? createConnection(address) : createConnection({ host: "127.0.0.1", port: (address as { port: number }).port });
			await new Promise<void>((done, fail) => { socket.once("connect", done); socket.once("error", fail); });
			descriptor = socket; t.after(() => socket.destroy());
		}
	}
	const child = spawn(binary!, ["memory-review-worker"], { stdio: ["pipe", "pipe", "pipe", descriptor], env: dream.workerEnvironment() });
	let output = ""; child.stdout!.on("data", (data: Buffer) => { output += data.toString("utf8"); });
	t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });
	const code = await new Promise<number | null>((done) => child.on("close", done));
	assert.equal(code, 1); const final = JSON.parse(output.trim()); assert.equal(final.status, "failed"); assert.match(final.reason, /at control/);
});
