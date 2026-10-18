import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import { syncBuiltinESMExports } from "node:module";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

import "./test/host.ts";
const { registerMemoryManagement } = await import("./management.ts");
const preview = { type: "preview", digest: "a".repeat(64), commit: "b".repeat(40), main: "b".repeat(40), isDetachRequired: true };
const tick = () => new Promise<void>((done) => setImmediate(done));

function fixture() {
	const child = new EventEmitter();
	const stdout = new PassThrough();
	const stderr = new PassThrough();
	const control = new PassThrough();
	const signals: string[] = [];
	Object.assign(child, { stdout, stderr, stdio: [null, stdout, stderr, control], kill: (signal: string) => { signals.push(signal); return true; } });
	let handler!: (args: string, ctx: ExtensionCommandContext) => Promise<void>;
	let spawns = 0;
	const original = childProcess.spawn;
	childProcess.spawn = ((_command: unknown, _args: unknown, options: { signal: AbortSignal }) => {
		spawns++;
		options.signal.addEventListener("abort", () => child.emit("error", new Error("AbortError")), { once: true });
		return child;
	}) as typeof childProcess.spawn;
	syncBuiltinESMExports();
	const shutdown = registerMemoryManagement({ registerTool: () => {}, registerCommand: (_name: string, command: { handler: typeof handler }) => { handler = command.handler; } } as unknown as ExtensionAPI);
	return { child, stdout, stderr, signals, shutdown, get spawns() { return spawns; }, handler,
		restore() { childProcess.spawn = original; syncBuiltinESMExports(); } };
}

test("preparation abort and shutdown await delayed child close, escalating only the owned child", async () => {
	const f = fixture();
	try {
		let isHandlerDone = false;
		let isShutdownDone = false;
		let open!: () => void;
		const selected = new Promise<void>((done) => { open = done; });
		const ctx = { cwd: "/unused", mode: "tui", hasUI: true, waitForIdle: async () => {}, ui: {
			select: (_title: string, _choices: string[], options: { signal: AbortSignal }) => { open(); return new Promise((_done, fail) => options.signal.addEventListener("abort", () => fail(new Error("selection aborted")), { once: true })); },
			notify: () => assert.fail("Cancelled preparation cannot notify success"),
		} } as unknown as ExtensionCommandContext;
		const handler = f.handler("", ctx).finally(() => { isHandlerDone = true; });
		const rejection = assert.rejects(handler, /abort/i);
		await tick();
		f.stdout.write(JSON.stringify(preview) + "\n");
		await selected;
		const shutdown = f.shutdown().then(() => { isShutdownDone = true; });
		await new Promise((done) => setTimeout(done, 1100));
		assert.equal(isHandlerDone, false);
		assert.equal(isShutdownDone, false);
		assert.deepEqual(f.signals, ["SIGTERM", "SIGKILL"]);
		f.child.emit("close", null, "SIGKILL");
		await Promise.all([rejection, shutdown]);
		assert.equal(isHandlerDone, true);
		assert.equal(isShutdownDone, true);
	} finally { f.restore(); }
});

for (const [name, bytes] of [
	["duplicate keys", Buffer.from(JSON.stringify(preview).replace('"type":"preview"', '"type":"preview","type":"preview"') + "\n")],
	["extra fields", Buffer.from(JSON.stringify({ ...preview, extra: true }) + "\n")],
	["invalid UTF-8", Buffer.from([0xff, 10])],
	["unterminated oversized frame", Buffer.alloc(65_537, 120)],
] as const) test(`preparation refuses ${name} before native selection`, async () => {
	const f = fixture();
	try {
		const ctx = { cwd: "/unused", mode: "tui", hasUI: true, waitForIdle: async () => {}, ui: { select: () => assert.fail("Invalid frame reached selection"), notify: () => assert.fail("Invalid frame reached success") } } as unknown as ExtensionCommandContext;
		const rejection = assert.rejects(f.handler("", ctx));
		await tick();
		f.stdout.write(bytes);
		await tick();
		assert.deepEqual(f.signals, ["SIGTERM"]);
		f.child.emit("close", 1);
		await rejection;
		await f.shutdown();
	} finally { f.restore(); }
});

test("preparation refusal retains legacy recovery guidance and waits for close", async () => {
	const f = fixture();
	try {
		let isDone = false;
		const ctx = { mode: "tui", hasUI: true, cwd: "/unused", waitForIdle: async () => {}, ui: {
			select: () => assert.fail("Refused checkout cannot reach selection"),
			notify: () => assert.fail("Refused checkout cannot report success"),
		} } as unknown as ExtensionCommandContext;
		const handler = f.handler("", ctx).finally(() => { isDone = true; });
		const rejection = assert.rejects(handler, (error: Error) => {
			assert.match(error.message, /Do not remove unknown Git locks automatically/);
			assert.match(error.message, /reopen \/mem-review with its original explicit configuration/);
			assert.ok(!error.message.includes("untrusted diagnostic"));
			return true;
		});
		await tick();
		f.stderr.write("untrusted diagnostic\u001b[31m\n");
		await tick();
		assert.equal(isDone, false);
		assert.deepEqual(f.signals, ["SIGTERM"]);
		f.child.emit("close", 1);
		await rejection;
		assert.equal(isDone, true);
		await f.shutdown();
	} finally { f.restore(); }
});

test("preparation waits for idle and cancellation while waiting never starts a worker", async () => {
	const f = fixture();
	try {
		let idle!: () => void;
		const ctx = { mode: "tui", hasUI: true, waitForIdle: () => new Promise<void>((done) => { idle = done; }) } as unknown as ExtensionCommandContext;
		const rejection = assert.rejects(f.handler("", ctx), /abort/i);
		const shutdown = f.shutdown();
		assert.equal(f.spawns, 0);
		idle();
		await Promise.all([rejection, shutdown]);
		assert.equal(f.spawns, 0);
	} finally { f.restore(); }
});
