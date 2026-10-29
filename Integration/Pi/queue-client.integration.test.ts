import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import "./test/host.ts";
import { sourceProtectionFixture } from "./test/source-protection.ts";
import { protectDreamSources } from "./source-protection.ts";
const { runDreamWorker } = await import("./dream.ts");
const { openQueueClient, decodeQueuePreview, queueObject } = await import("./queue-client.ts");
const binary = process.env.PI_CORE_MEMORIES_BIN ?? process.env.PI_CORE_MEMORIES_EXECUTABLE;
assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the verified release command");

test("two native sessions share ownership and persisted same-request deferral after owner death", { timeout: 20_000 }, async (t) => {
	const root = await mkdtemp("/private/tmp/memory-queue-host-");
	const previous = process.env.PI_CORE_MEMORIES_EXECUTABLE;
	process.env.PI_CORE_MEMORIES_EXECUTABLE = binary;
	const previousFetch = globalThis.fetch;
	globalThis.fetch = async () => assert.fail("No network");
	t.after(async () => {
		globalThis.fetch = previousFetch;
		if (previous === undefined) delete process.env.PI_CORE_MEMORIES_EXECUTABLE; else process.env.PI_CORE_MEMORIES_EXECUTABLE = previous;
		await rm(root, { recursive: true, force: true });
	});
	const repo = join(root, "memory"); const sessions = join(root, "sessions");
	await mkdir(join(sessions, "fixture"), { recursive: true, mode: 0o700 });
	execFileSync(binary!, ["init", "--repo", repo]);
	await writeFile(join(sessions, "fixture", "archive.jsonl"), [
		{ type: "session", version: 3, id: "archive", timestamp: "1999-01-01T00:00:00Z", cwd: root },
		{ type: "message", id: "entry", parentId: null, timestamp: "1999-01-01T00:00:00Z", message: { role: "user", content: "Keep exact synthetic preferences.", timestamp: 0 } },
	].map((record) => JSON.stringify(record) + "\n").join(""));
	const roots = { state: join(root, "dream"), sessions, memory: repo, snippets: null, prompts: null, globalAgents: null };
	const report = await runDreamWorker({ version: 1, type: "start", invocationID: "fixture", roots, selection: { provider: "fixture", modelID: "selected", thinkingLevel: "off" }, resume: "inspectOrContinue", batchTextBytes: 262_144 }, async (request) => {
		const source = JSON.parse(request.messages[0].text).primaryEvidence[0].source;
		return JSON.stringify({ schemaVersion: 1, contextHash: request.contextHash, decisions: [{ kind: "add", scope: { kind: "global" }, text: "Keep exact synthetic preferences.", sources: [source], contradictions: [], reason: "An explicit synthetic preference." }] });
	}, new AbortController().signal, undefined, (value, signal) => protectDreamSources(sourceProtectionFixture(), "fixture", value, signal));
	assert.equal(report.status, "completed");
	const configDirectory = join(root, "config"); await mkdir(configDirectory, { mode: 0o700 });
	const config = join(configDirectory, "config.json");
	await writeFile(config, JSON.stringify({ schemaVersion: 1, settings: { schemaVersion: 1, piExecutable: "/usr/bin/true", agentDirectory: join(root, "agent") }, roots, journal: join(root, "journal"), reviewState: join(root, "review"), diagnostics: join(root, "diagnostics"), projectBindings: {} }), { mode: 0o600 });
	const identity = { sessionID: "host-one", requestID: "durable-user-entry" };
	const controller = new AbortController();
	const first = await openQueueClient(root, controller.signal, config); t.after(() => first.close());
	const second = await openQueueClient(root, new AbortController().signal, config); t.after(() => second.close());
	const list = await first.request("list", { ...identity, offset: "0" });
	const rows = list.rows as { finding: { revision: string } }[];
	assert.ok(rows.length > 0);
	const revision = rows[0].finding.revision;
	const preview = decodeQueuePreview(await first.request("claim", { ...identity, revision }), identity);
	assert.equal((await second.request("list", { sessionID: "host-two", requestID: "other-request", offset: "0" })).code, "busy");
	controller.abort(); await first.close();
	const nextIdentity = { ...identity, requestID: "later-user-entry" };
	const next = decodeQueuePreview(await second.request("claim", { ...nextIdentity, revision }), nextIdentity);
	assert.notEqual(next.tuple.claimID, preview.tuple.claimID);
	assert.equal((await second.request("presented", { ...next.tuple, messageReference: "visible-message" }, true)).displayDigest, next.digest);
	const decision = await second.request("reply", { ...next.tuple, originalText: "Leave that memory for later", submittedText: "Leave that memory for later", decisionID: "explicit-deferral", responseReference: "original-response" }, true);
	assert.equal(queueObject(decision.receipt).status, "deferred");
	await second.close();
	const restarted = await openQueueClient(root, new AbortController().signal, config); t.after(() => restarted.close());
	const retained = await restarted.request("list", { ...nextIdentity, offset: "0" });
	assert.ok(JSON.stringify(retained).includes("already-presented-for-request"));
	const distinct = await restarted.request("list", { ...identity, requestID: "another-real-request", offset: "0" });
	assert.ok(!JSON.stringify(distinct).includes("already-presented-for-request"));
});
