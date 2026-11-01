import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test, type TestContext } from "node:test";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { DreamCoverage, DreamRequest, DreamStart } from "./dream.ts";
type RegistryFixture = Pick<ExtensionContext["modelRegistry"], "streamSimple">;
const subscription = { isUsingOAuth: () => true, getProvider: () => ({ auth: { oauth: { isSubscription: true } } }) };

import { sdkURL, aiURL } from "./test/host.ts";
const nativeDream = await import("./dream.ts");
const { protectDreamSources } = await import("./source-protection.ts");
const { sourceProtectionFixture } = await import("./test/source-protection.ts");
const dream = {
	...nativeDream,
	runDreamWorker: (...args: Parameters<typeof nativeDream.runDreamWorker>) => nativeDream.runDreamWorker(args[0], args[1], args[2], args[3], args[4] ?? ((value, signal) => protectDreamSources(sourceProtectionFixture(), args[0].invocationID, value, signal))),
};
const sdk = await import(sdkURL) as typeof import("@earendil-works/pi-coding-agent");
const ai = await import(aiURL) as typeof import("@earendil-works/pi-ai");
const binary = process.env.PI_CORE_MEMORIES_BIN ?? process.env.PI_CORE_MEMORIES_EXECUTABLE;
assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the verified release command");

async function fixture(t: TestContext, isPrimary = true) {
	const root = await mkdtemp("/private/tmp/pi-dream-adapter-");
	const home = join(root, "home"); const agent = join(home, "agent"); const repo = join(root, "memory ' ; $repo"); const bin = join(root, "bin");
	const previous = Object.fromEntries(["HOME", "PI_CORE_MEMORIES_EXECUTABLE", "PI_CORE_MEMORIES_REPO", "PI_CODING_AGENT_DIR"].map((name) => [name, process.env[name]]));
	const previousFetch = globalThis.fetch; let networkCalls = 0;
	globalThis.fetch = async () => { networkCalls++; throw new Error("Network forbidden"); };
	t.after(async () => {
		globalThis.fetch = previousFetch;
		for (const [name, value] of Object.entries(previous)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
		await rm(root, { recursive: true, force: true }); assert.equal(networkCalls, 0);
	});
	await mkdir(agent, { recursive: true });
	process.env.HOME = home; process.env.PI_CODING_AGENT_DIR = agent; process.env.PI_CORE_MEMORIES_REPO = repo; process.env.PI_CORE_MEMORIES_EXECUTABLE = resolve(binary!);
	const cli = (...args: string[]) => execFileSync(binary!, args, { encoding: "utf8" });
	cli("init", "--repo", repo);
	const folder = join(agent, "sessions", "synthetic-project"); await mkdir(folder, { recursive: true });
	const sessionFile = join(folder, "synthetic.jsonl");
	await writeFile(sessionFile, [
		{ type: "session", version: 3, id: "synthetic-session", timestamp: "1999-01-01T00:00:00.000Z", cwd: root },
		...(isPrimary ? [{ type: "message", id: "entry", parentId: null, timestamp: "1999-01-01T00:00:00.000Z", message: { role: "user", content: "Use green buttons, café 🌱, not blue.", timestamp: 0 } }] : []),
	].map((entry) => JSON.stringify(entry) + "\n").join(""));
	const roots = await dream.dreamRoots(agent, root);
	const selection = { provider: "openai", modelID: "selected", thinkingLevel: "off" };
	const start: DreamStart = { version: 1, type: "start", invocationID: "synthetic-invocation", roots, selection, resume: "inspectOrContinue", batchTextBytes: 262_144 };
	return { root, home, agent, repo, bin, roots, start, sessionFile, cli };
}
function decision(request: DreamRequest, isProposal = false): string {
	const context = JSON.parse(request.messages[0].text) as { primaryEvidence: { source: unknown }[] };
	return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: context.primaryEvidence.map((entry) => isProposal ? { kind: "add", scope: { kind: "global" }, text: "Use green buttons.", sources: [entry.source], contradictions: [], reason: "Retain the preference." } : { kind: "noChange", sources: [entry.source], reasonCode: "notDurable", explanation: "Synthetic café 🌱 note." }) });
}

test("real worker publishes exact refs and notes once, saved retry and no-new use zero registry calls", async (t) => {
	for (const isProposal of [false, true]) {
		const f = await fixture(t); let calls = 0;
		const sourceBefore = await readFile(f.sessionFile); const approvedBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
		const first = await dream.runDreamWorker(f.start, async (request) => { calls++; return decision(request, isProposal); }, new AbortController().signal);
		assert.equal(first.status, "completed"); assert.equal(first.generation, "1"); assert.equal(calls, 1);
		assert.equal(first.proposals.length, isProposal ? 1 : 0); assert.equal(first.notes.length, isProposal ? 0 : 1);
		if (isProposal) {
			const proposal = first.proposals[0];
			const review = f.cli("review", "--repo", f.repo, proposal.commit);
			assert.ok(review.includes(proposal.base)); assert.match(review, /Use green buttons/); assert.match(review, /HUMAN/);
		}
		const forbidden = async () => { assert.fail("No registry call allowed on replay"); };
		const recovered = await dream.runDreamWorker({ ...f.start, selection: { provider: "anthropic", modelID: "other", thinkingLevel: "high" }, resume: "retryInterruptedCall" }, forbidden, new AbortController().signal);
		assert.equal(recovered.status, "completed"); assert.equal(recovered.isRecovered, true); assert.deepEqual(recovered.proposals, first.proposals);
		const next = await dream.runDreamWorker(f.start, forbidden, new AbortController().signal);
		assert.equal(next.status, "noNewRecords"); assert.equal(next.generation, "1");
		assert.deepEqual(await readFile(f.sessionFile), sourceBefore); assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), approvedBefore);
	}
});

test("manual replacement refuses another saved run or request before any model call", async (t) => {
	const f = await fixture(t);
	const invalid = await dream.runDreamWorker(f.start, async (request) => {
		const response = JSON.parse(decision(request)) as { decisions: { reasonCode: string }[] };
		response.decisions[0]!.reasonCode = "unresolvedScope";
		return JSON.stringify(response);
	}, new AbortController().signal);
	assert.equal(invalid.status, "pending"); assert.equal(invalid.reason, "invalidDecision");
	const directory = join(f.roots.state, "runs", invalid.runID!);
	const original = await readFile(join(directory, "response.json"));
	const requestHash = createHash("sha256").update(await readFile(join(directory, "request.json"))).digest("hex");
	let calls = 0;
	const wrong = await dream.runDreamWorker({ ...f.start, resume: "replaceInvalidResponse", recoveryTarget: { runID: invalid.runID!, requestHash: "0".repeat(64) } }, async () => { calls++; assert.fail("wrong request must not call"); }, new AbortController().signal);
	assert.equal(wrong.status, "blocked"); assert.equal(calls, 0);
	assert.deepEqual(await readFile(join(directory, "response.json")), original);
	const recovered = await dream.runDreamWorker({ ...f.start, resume: "replaceInvalidResponse", recoveryTarget: { runID: invalid.runID!, requestHash } }, async (request) => { calls++; return decision(request); }, new AbortController().signal);
	assert.equal(recovered.status, "completed"); assert.equal(calls, 1);
	assert.deepEqual(await readFile(join(directory, "response.json")), original);
	assert.deepEqual(await readFile(join(directory, "rejected-1.json")), original);
});

test("interrupted call stays pending, explicit retry uses exact saved input after source deletion", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined;
	const controller = new AbortController();
	const pending = await dream.runDreamWorker(f.start, async (request) => { saved = request; controller.abort(); throw new Error("cancel"); }, controller.signal);
	assert.equal(pending.status, "pending"); assert.equal(pending.reason, "cancelled");
	await rm(f.roots.sessions, { recursive: true });
	const roots = await dream.dreamRoots(f.agent, f.root);
	assert.deepEqual(roots, f.roots);
	const inspect = await dream.runDreamWorker({ ...f.start, roots }, async () => { assert.fail("inspect must not call"); }, new AbortController().signal);
	assert.equal(inspect.status, "pending"); assert.equal(inspect.reason, "interruptedCall");
	const completed = await dream.runDreamWorker({ ...f.start, roots, resume: "retryInterruptedCall" }, async (request) => { assert.deepEqual(request, saved); return decision(request); }, new AbortController().signal);
	assert.equal(completed.status, "completed"); assert.equal(completed.generation, "1");
});

test("real worker reports the provider's error cause but never its response, saves no response, and calls again only on explicit retry", async (t) => {
	const f = await fixture(t); let saved: DreamRequest | undefined; let calls = 0;
	const model = { provider: f.start.selection.provider, id: f.start.selection.modelID, api: "offline" } as Parameters<typeof dream.callDreamModel>[2];
	const memoryBefore = f.cli("render", "--repo", f.repo, "--cwd", f.root);
	const report = await dream.runDreamWorker(f.start, async (request, signal) => {
		saved = request;
		const registry = { streamSimple(current) {
			calls++;
			const reply: AssistantMessage = { role: "assistant", api: current.api, provider: current.provider, model: current.id, content: [{ type: "text", text: "PRIVATE PARTIAL RESPONSE" }], stopReason: "error", errorMessage: "fixture provider quota exceeded", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
			const stream = ai.createAssistantMessageEventStream(); stream.push({ type: "error", reason: "error", error: reply }); return stream;
		} } satisfies RegistryFixture;
		return dream.callDreamModel(request, { modelRegistry: { ...subscription, ...registry } as unknown as Parameters<typeof dream.callDreamModel>[1]["modelRegistry"] }, model, f.start.selection, signal);
	}, new AbortController().signal);
	assert.equal(report.status, "pending"); assert.equal(report.reason, "callbackFailure"); assert.equal(report.generation, "0"); assert.equal(calls, 1);
	assert.equal(report.detail, "Dream model call failed: error: fixture provider quota exceeded");
	const display = dream.dreamReviewText(report);
	assert.ok(display.includes(`Cause: ${report.detail}`)); assert.ok(display.includes("Discuss recovery in conversation before another model call.")); assert.ok(!display.includes("/dream")); assert.ok(!display.includes("PRIVATE PARTIAL RESPONSE"));
	const directory = join(f.roots.state, "runs", report.runID!);
	await assert.rejects(readFile(join(directory, "response.json")), { code: "ENOENT" });
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
	const inspect = await dream.runDreamWorker(f.start, async () => { assert.fail("Inspection must not repeat the failed model call"); }, new AbortController().signal);
	assert.equal(inspect.status, "pending"); assert.equal(inspect.reason, "interruptedCall"); assert.equal(calls, 1);
	await assert.rejects(readFile(join(directory, "response.json")), { code: "ENOENT" });
	const completed = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, async (request) => {
		calls++; assert.deepEqual(request, saved); return decision(request);
	}, new AbortController().signal);
	assert.equal(completed.status, "completed"); assert.equal(completed.runID, report.runID); assert.equal(completed.generation, "1"); assert.equal(calls, 2);
	assert.equal(f.cli("render", "--repo", f.repo, "--cwd", f.root), memoryBefore);
});

test("concurrent worker is busy while first registry call holds the core lock", async (t) => {
	const f = await fixture(t); let release!: () => void; let entered!: () => void;
	const wait = new Promise<void>((done) => { release = done; }); const ready = new Promise<void>((done) => { entered = done; });
	const first = dream.runDreamWorker(f.start, async (request) => { entered(); await wait; return decision(request); }, new AbortController().signal);
	await ready;
	const second = await dream.runDreamWorker({ ...f.start, invocationID: "second" }, async () => { assert.fail("busy must not call"); }, new AbortController().signal);
	assert.equal(second.status, "busy"); release(); assert.equal((await first).status, "completed");
});

test("live coverage commits only after success and retry keeps frozen bytes when new records arrive", async (t) => {
	const f = await fixture(t);
	const bytes = Buffer.byteLength("Use green buttons, café 🌱, not blue.");
	const firstFrames: DreamCoverage[] = [];
	const first = await dream.runDreamWorker(f.start, async () => { throw new Error("interrupted"); }, new AbortController().signal, (frame) => firstFrames.push(frame));
	assert.equal(first.status, "pending");
	assert.deepEqual(firstFrames.map((frame) => [frame.backlogBytes, frame.plannedBytes, frame.completedBytes, frame.undreamtBytes, frame.nextBytes]), [[bytes, bytes, 0, bytes, 0]]);
	const extra = JSON.stringify({ type: "message", id: "extra", parentId: "entry", timestamp: "1999-01-01T00:00:00.000Z", message: { role: "user", content: "Prefer small buttons." } }) + "\n";
	await writeFile(f.sessionFile, await readFile(f.sessionFile, "utf8") + extra);
	const inspectFrames: DreamCoverage[] = [];
	const inspected = await dream.runDreamWorker(f.start, async () => { assert.fail("Inspection must not repeat the call"); }, new AbortController().signal, (frame) => inspectFrames.push(frame));
	assert.equal(inspected.status, "pending");
	assert.equal(inspectFrames[0].repeatedRecords, 1);
	assert.equal(inspectFrames[0].completedBytes, 0);
	await rm(f.roots.sessions, { recursive: true });
	const retryFrames: DreamCoverage[] = [];
	const retry = await dream.runDreamWorker({ ...f.start, resume: "retryInterruptedCall" }, async (request) => decision(request), new AbortController().signal, (frame) => retryFrames.push(frame));
	assert.equal(retry.status, "completed");
	assert.deepEqual(retryFrames.map((frame) => [frame.backlogBytes, frame.plannedBytes, frame.completedBytes, frame.undreamtBytes, frame.nextBytes, frame.repeatedRecords]), [[null, bytes, 0, null, null, 1], [null, bytes, bytes, null, null, 1]]);
	assert.equal(retryFrames[0].estimateSeconds, null);
	const timing = JSON.parse(await readFile(join(f.roots.state, "timing.json"), "utf8"));
	assert.ok(timing.seconds > 0); assert.equal(timing.records, 2); assert.equal(timing.inputBytes, bytes);
});

