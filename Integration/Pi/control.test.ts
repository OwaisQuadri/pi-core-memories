import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { DreamReport, DreamRoots, DreamSelection, DreamStart, runDreamWorker, callDreamModel } from "./dream.ts";

import "./test/host.ts";
const { parseControlRequest, registerDreamControl } = await import("./control.ts");
const roots: DreamRoots = { state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null };
const selection: DreamSelection = { provider: "fixture", modelID: "chosen", thinkingLevel: "medium" };
const report: DreamReport = { version: 1, type: "final", invocationID: "fixture", status: "noNewRecords", generation: "0", runID: null, base: null, proposals: [], notes: [], isBacklog: false, isRecovered: false, reason: null, detail: null, unfinishedTails: 0 };
const json = (operation = "start", chosenRoots: DreamRoots | null = roots) => JSON.stringify({ operation, roots: chosenRoots });

function fixture(run: typeof runDreamWorker, call: typeof callDreamModel = async () => assert.fail("No model call expected"), scopeFor: Parameters<typeof registerDreamControl>[4] = async () => ({})) {
	const commands = new Map<string, { handler: (args: string, ctx: ExtensionCommandContext) => Promise<void> }>();
	const events = new Map<string, () => Promise<void>>();
	const notices: Record<string, unknown>[] = [];
	let idle = 0;
	let rootCalls = 0;
	const pi = { registerCommand: (name: string, value: { handler: (args: string, ctx: ExtensionCommandContext) => Promise<void> }) => commands.set(name, value), on: (name: string, value: () => Promise<void>) => events.set(name, value), getThinkingLevel: () => "off" } as unknown as ExtensionAPI;
	const ctx = { mode: "rpc", cwd: "/work", model: { provider: selection.provider, id: selection.modelID, contextWindow: 262_144 }, thinkingLevel: selection.thinkingLevel, waitForIdle: async () => { idle++; }, ui: { notify: (text: string) => notices.push(JSON.parse(text)) } } as unknown as ExtensionCommandContext;
	const abort = registerDreamControl(pi, run, async () => { rootCalls++; return roots; }, call, scopeFor);
	return { commands, events, notices, ctx, abort, get idle() { return idle; }, get rootCalls() { return rootCalls; }, start: (args = json()) => commands.get("memory-dream-control")!.handler(args, ctx), cancel: () => commands.get("memory-dream-cancel")!.handler("", ctx) };
}

test("control rejects approval verbs, duplicate keys and malformed roots before execution", async () => {
	for (const text of [json("approve"), json("inspect"), '{"operation":["retry"],"roots":null}', '{"operation":["replace"],"roots":null}', '{"operation":"start","operation":"replace","roots":null}', JSON.stringify({ operation: "start", roots, extra: true }), JSON.stringify({ operation: "start", roots: { ...roots, memory: "relative" } }), JSON.stringify({ operation: "start", roots: { ...roots, memory: null } }), JSON.stringify({ operation: "start", roots: { ...roots, extra: "/extra" } })]) assert.throws(() => parseControlRequest(text));
	assert.deepEqual(parseControlRequest(json("replace")), { operation: "replace", roots });
	assert.deepEqual(parseControlRequest(json("start", null)), { operation: "start", roots: null });
	const f = fixture(async () => assert.fail("Invalid input must not reach the worker"));
	await f.start(json("approve"));
	assert.equal(f.idle, 0);
	assert.equal(f.rootCalls, 0);
	assert.equal(f.notices[0].event, "error");
});

test("control captures Pi selection once and does not call a model when the worker replays saved work", async () => {
	const starts: DreamStart[] = [];
	const f = fixture(async (start) => { starts.push(start); return { ...report, invocationID: start.invocationID }; });
	await f.start(json("replace", null));
	assert.equal(starts.length, 1);
	assert.deepEqual(starts[0].selection, selection);
	assert.equal(starts[0].resume, "replaceInvalidResponse");
	assert.equal(starts[0].batchTextBytes, 262_144);
	assert.deepEqual(starts[0].roots, roots);
	assert.equal(f.rootCalls, 1);
	assert.deepEqual(f.notices.map((event) => event.event), ["selection", "phase", "report"]);
	assert.equal(f.ctx.model!.id, selection.modelID);
});

test("control preserves explicit device and shared-project scope without changing old requests", async () => {
	const deviceKey = "d".repeat(64);
	const projectBindings = { "/project/.git": "a".repeat(64) };
	let captured: DreamStart | undefined;
	const f = fixture(async (start) => { captured = start; return report; });
	const request = { operation: "start", roots, deviceKey, projectBindings };
	assert.deepEqual(parseControlRequest(JSON.stringify(request)), request);
	await f.start(JSON.stringify(request));
	assert.equal(captured!.deviceKey, deviceKey);
	assert.deepEqual(captured!.projectBindings, projectBindings);
	for (const invalid of [{ ...request, deviceKey: "device-name" }, { ...request, projectBindings: { relative: "a".repeat(64) } }, { ...request, projectBindings: { "/project/.git": "invalid" } }]) assert.throws(() => parseControlRequest(JSON.stringify(invalid)));
});

test("an explicit empty profile scope does not inherit the default profile device", async () => {
	let captured: DreamStart | undefined;
	let scopeCalls = 0;
	const f = fixture(async (start) => { captured = start; return report; }, undefined, async () => {
		scopeCalls++;
		return { deviceKey: "d".repeat(64), projectBindings: { "/default/.git": "a".repeat(64) } };
	});
	await f.start(JSON.stringify({ operation: "start", roots: null, projectBindings: {} }));
	assert.equal(scopeCalls, 0);
	assert.equal(captured!.deviceKey, undefined);
	assert.deepEqual(captured!.projectBindings ?? {}, {});
	assert.equal(f.rootCalls, 1);
});

test("control refuses a missing model or a small context before starting a worker", async () => {
	for (const model of [undefined, { provider: "fixture", id: "chosen", contextWindow: 32_768 }]) {
		const f = fixture(async () => assert.fail("Invalid selection must not reach the worker"));
		const ctx = f.ctx as unknown as { model: unknown };
		ctx.model = model;
		await f.start();
		assert.equal(f.notices.length, 1);
		assert.equal(f.notices[0].event, "error");
	}
});

test("all stops on the first pending report instead of retrying a billable call", async () => {
	let runs = 0;
	const f = fixture(async () => { runs++; return { ...report, status: runs === 1 ? "completed" : "pending", isBacklog: true }; });
	await f.start(json("all"));
	assert.equal(runs, 2);
	assert.equal(f.notices.filter((event) => event.event === "batchReport").length, 1);
	assert.equal(f.notices.filter((event) => event.event === "report").length, 1);
	assert.equal((f.notices.at(-1)!.report as DreamReport).status, "pending");
});

test("cancel waits for owned worker cleanup and a concurrent start does not dispatch", async () => {
	let ready!: () => void;
	const entered = new Promise<void>((resolve) => { ready = resolve; });
	let isCleaned = false;
	let runs = 0;
	const f = fixture(async (_start, _call, signal) => {
		runs++;
		await new Promise<void>((resolve) => { signal.addEventListener("abort", () => resolve(), { once: true }); ready(); });
		isCleaned = true;
		return { ...report, status: "pending", reason: "cancelled" };
	});
	const work = f.start();
	await entered;
	await f.start();
	assert.equal(runs, 1);
	assert.ok(f.notices.some((event) => event.event === "error" && event.detail === "Dream control is busy."));
	await f.cancel();
	await work;
	assert.equal(isCleaned, true);
	assert.equal((f.notices.at(-1)!.report as DreamReport).reason, "cancelled");
});

test("cancel and shutdown interrupt an idle wait without aborting unrelated agent work", async () => {
	for (const action of ["cancel", "shutdown"]) {
		const f = fixture(async () => assert.fail("Cancellation during idle wait must not start a worker"));
		(f.ctx as unknown as { waitForIdle: () => Promise<void> }).waitForIdle = () => new Promise(() => {});
		const work = f.start();
		if (action === "cancel") await f.cancel();
		else await f.events.get("session_shutdown")!();
		await work;
		assert.equal(f.rootCalls, 0);
		assert.equal(f.notices.length, 1);
		assert.equal(f.notices[0].event, "error");
		assert.equal(f.notices[0].detail, "Dream cancelled before it started.");
	}
});

test("control forwards worker requests without adding conversation context", async () => {
	const saved = { selection, systemPrompt: "pinned", messages: [] } as unknown as Parameters<typeof callDreamModel>[0];
	let calls = 0;
	const f = fixture(async (_start, call, signal) => {
		assert.equal(await call(saved, signal), "saved reply");
		return report;
	}, async (request, ctx, model, captured, signal) => {
		calls++;
		assert.strictEqual(request, saved);
		assert.strictEqual(ctx, f.ctx);
		assert.strictEqual(model, f.ctx.model);
		assert.deepEqual(captured, selection);
		assert.equal(signal.aborted, false);
		return "saved reply";
	});
	await f.start();
	assert.equal(calls, 1);
	assert.deepEqual(f.notices.filter((event) => event.event === "phase").map((event) => event.phase), ["planning", "modelCall", "saving"]);
});

test("control bounds errors and redacts credential values from diagnostics", async () => {
	const name = "MEMORY_TEST_API_KEY";
	const old = process.env[name];
	process.env[name] = "private-fixture-credential";
	try {
		const f = fixture(async () => { throw new Error("Failure private-fixture-credential Bearer fixture-bearer-secret\u001b" + "x".repeat(2000)); });
		await f.start();
		const text = String(f.notices.at(-1)!.detail);
		assert.ok(!text.includes("private-fixture-credential"));
		assert.ok(!text.includes("fixture-bearer-secret"));
		assert.ok(!text.includes("\u001b"));
		assert.ok(Buffer.byteLength(text) <= 1000);
		const unicode = fixture(async () => { throw new Error("🌱".repeat(1000)); });
		await unicode.start();
		const bounded = String(unicode.notices.at(-1)!.detail);
		assert.ok(Buffer.byteLength(bounded) <= 1000);
		assert.ok(!bounded.includes("\uFFFD"));
		const raw = { ...report, status: "pending" as const, detail: "Provider failure private-fixture-credential Bearer fixture-bearer-secret" };
		const returned = fixture(async () => raw);
		await returned.start();
		const safe = (returned.notices.at(-1)!.report as DreamReport).detail!;
		assert.ok(!safe.includes("private-fixture-credential"));
		assert.ok(!safe.includes("fixture-bearer-secret"));
		assert.ok(raw.detail.includes("private-fixture-credential"));
	} finally { if (old === undefined) delete process.env[name]; else process.env[name] = old; }
});
