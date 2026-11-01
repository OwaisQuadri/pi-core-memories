import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import type { TestContext } from "node:test";
import { runDreamWorker, type DreamStart } from "./dream.ts";
import { sourceProtectionDigest } from "./source-protection.ts";

const sentinel = "SYNTHETIC_PRIVATE_FRAME_SENTINEL";
const start: DreamStart = { version: 1, type: "start", invocationID: "fixture", roots: { state: "/state", sessions: "/sessions", memory: "/memory", snippets: null, prompts: null, globalAgents: null }, selection: { provider: "fixture", modelID: "selected", thinkingLevel: "off" }, resume: "inspectOrContinue", batchTextBytes: 262_144 };
const protection = { version: 1, type: "sourceProtectionRequest", invocationID: "fixture", requestID: "private", inputDigest: sourceProtectionDigest([sentinel]), pieces: [sentinel] };
async function worker(t: TestContext, body: string) {
	const root = await mkdtemp("/private/tmp/private-source-fixture-");
	const prior = process.env.PI_CORE_MEMORIES_EXECUTABLE;
	const executable = join(root, "pi-core-memories");
	await writeFile(executable, `#!${process.execPath}\n${body}\n`, { mode: 0o755 });
	process.env.PI_CORE_MEMORIES_EXECUTABLE = executable;
	t.after(async () => { if (prior === undefined) delete process.env.PI_CORE_MEMORIES_EXECUTABLE; else process.env.PI_CORE_MEMORIES_EXECUTABLE = prior; await rm(root, { recursive: true, force: true }); });
}
function isPrivateFailure(error: unknown): boolean {
	assert.ok(error instanceof Error);
	assert.ok(!error.message.includes(sentinel));
	return true;
}

test("private source frames without a protection capability cannot reach the model", { timeout: 5000 }, async (t) => {
	await worker(t, `process.stdin.once('data',()=>process.stdout.write(${JSON.stringify(JSON.stringify(protection) + "\n")}));`);
	await assert.rejects(runDreamWorker(start, async () => { assert.fail("No unchecked model call"); }, new AbortController().signal), isPrivateFailure);
});

test("model dispatch requires a completed checked source exchange", { timeout: 5000 }, async (t) => {
	const request = { version: 1, type: "modelRequest", invocationID: "fixture", requestID: "run:" + "a".repeat(64), runID: "run", generation: "0", inputHash: "b".repeat(64), contextHash: "c".repeat(64), requestHash: "a".repeat(64), selection: start.selection, systemPrompt: sentinel, messages: [{ role: "user", text: sentinel, timestampMilliseconds: 0 }] };
	await worker(t, `process.stdin.once('data',()=>process.stdout.write(${JSON.stringify(JSON.stringify(request) + "\n")}));`);
	await assert.rejects(runDreamWorker(start, async () => { assert.fail("No unchecked model call"); }, new AbortController().signal), isPrivateFailure);
});

for (const kind of ["malformed", "stderr"] as const) test(`private ${kind} bytes do not become visible diagnostics`, { timeout: 5000 }, async (t) => {
	const body = kind === "stderr" ? `process.stderr.write(${JSON.stringify(sentinel)}); process.exit(1);` : `process.stdout.write(${JSON.stringify('{"' + sentinel + '":')}); process.exit(1);`;
	await worker(t, `process.stdin.once('data',()=>{${body}});`);
	await assert.rejects(runDreamWorker(start, async () => { assert.fail("No model call"); }, new AbortController().signal), isPrivateFailure);
});
