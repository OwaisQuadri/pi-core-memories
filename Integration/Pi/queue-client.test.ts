import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { mkdtemp, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import "./test/host.ts";
const { decodeQueuePreview, openQueueClient } = await import("./queue-client.ts");
const identity = { sessionID: "session", requestID: "request" };
const sha = (value: Uint8Array): string => createHash("sha256").update(value).digest("hex");
const bytes = (value: string): string => Buffer.from(value).toString("base64");
export function presentation(isDetachRequired = false) {
	const payload = {
		claimID: "private-claim", sequence: "1", request: identity,
		finding: { revision: "a".repeat(64), candidateID: "b".repeat(64), reason: "Exact reason", proposed: bytes("  finding [source: synthetic; added: 2026-10-24]\n"), evidence: [{ exactText: "Use exact bytes", contentDigest: "c".repeat(64) }], limitations: ["synthetic limitation"] },
		previewDigest: "d".repeat(64), currentBase: "e".repeat(40), before: bytes("old\n"), after: bytes("  finding\n"), replacement: bytes("# Memory\n\n  finding\n"), isDetachRequired,
	};
	const encoded = Buffer.from(JSON.stringify(payload));
	return { type: "presentation", display: { presentation: payload, displayDigest: sha(encoded) }, displayBytes: encoded.toString("base64") };
}

test("verified preview decodes complete exact annotations and final document instead of base64", () => {
	const result = decodeQueuePreview(presentation(), identity);
	assert.ok(result.details.includes("  finding [source: synthetic; added: 2026-10-24]\n"));
	assert.ok(result.details.includes("# Memory\n\n  finding\n"));
	assert.ok(result.details.includes("synthetic limitation"));
	assert.equal(result.tuple.claimID, "private-claim");
});

test("amended preview shows its changed reason without replacing the historical reason", () => {
	const original = presentation();
	const reason = "Correct the wording from this conversation; preserve the original source.";
	const payload = { ...original.display.presentation, amendmentReason: reason };
	const encoded = Buffer.from(JSON.stringify(payload));
	const frame = { ...original, display: { presentation: payload, displayDigest: sha(encoded) }, displayBytes: encoded.toString("base64") };
	const result = decodeQueuePreview(frame, identity);
	assert.ok(result.details.includes("amendmentReason:\n  " + reason));
	assert.ok(result.details.includes(original.display.presentation.finding.reason));
	assert.equal(result.digest, sha(encoded));
	payload.amendmentReason = "A different reason must not reuse this display.";
	assert.throws(() => decodeQueuePreview(frame, identity));
});

test("tampered digest, mismatched display, foreign request and oversized preview cannot authorize", () => {
	const changedDigest = presentation(); changedDigest.display.displayDigest = "f".repeat(64);
	assert.throws(() => decodeQueuePreview(changedDigest, identity));
	const changedPayload = presentation(); changedPayload.display.presentation.finding.reason = "changed";
	assert.throws(() => decodeQueuePreview(changedPayload, identity));
	assert.throws(() => decodeQueuePreview(presentation(), { ...identity, requestID: "other" }));
	const oversized = presentation(); oversized.display.presentation.finding.reason = "x".repeat(65_537);
	const encoded = Buffer.from(JSON.stringify(oversized.display.presentation));
	oversized.displayBytes = encoded.toString("base64"); oversized.display.displayDigest = sha(encoded);
	assert.throws(() => decodeQueuePreview(oversized, identity), /too large/);
});

test("terminal controls and literal escape sequences render distinctly without changing native digest", () => {
	const frame = presentation();
	frame.display.presentation.before = bytes("\u001b[31m\\u{1B}\u202e");
	const encoded = Buffer.from(JSON.stringify(frame.display.presentation));
	frame.displayBytes = encoded.toString("base64"); frame.display.displayDigest = sha(encoded);
	const result = decodeQueuePreview(frame, identity);
	assert.ok(result.details.includes("\\u{1B}[31m\\u{5C}u{1B}\\u{202E}"));
	assert.equal(result.digest, sha(encoded));
});

test("management preview hashes native bytes with only displayDigest excluded and shows full documents", () => {
	const payload = { claimID: "management-private", sequence: "1", request: identity, currentBase: "a".repeat(40), previewDigest: "b".repeat(64), operation: "delete", reason: "Exact requested correction", path: "MEMORY.md", before: bytes("old annotated entry\n"), after: "", documentBefore: bytes("# Memory\n\nold annotated entry\n"), replacement: bytes("# Memory\n\n"), isDetachRequired: false };
	const encoded = Buffer.from(JSON.stringify(payload));
	const frame = { type: "manage-presentation", display: { ...payload, displayDigest: sha(encoded) }, displayBytes: encoded.toString("base64") };
	const result = decodeQueuePreview(frame, identity);
	assert.equal(result.isManagement, true);
	assert.equal(result.tuple.revision, payload.currentBase);
	assert.ok(result.details.includes("# Memory\n\nold annotated entry\n"));
	assert.ok(result.details.includes("Exact requested correction"));
	frame.display.path = "different";
	assert.throws(() => decodeQueuePreview(frame, identity));
});

test("native child keeps private choices on descriptor three and sanitizes stderr failures", async (t) => {
	const directory = await mkdtemp(join(tmpdir(), "memory-queue-client-"));
	const executable = join(directory, "worker.mjs");
	await writeFile(executable, `#!/usr/bin/env node
import { createInterface } from "node:readline";
import { createReadStream } from "node:fs";
function input(stream, channel) {
 createInterface({ input: stream }).on("line", (line) => {
  const frame = JSON.parse(line);
  if (frame.isSilent) return;
  if (frame.type === "stderr") { process.stderr.write("synthetic-private-marker"); return; }
  if (frame.type === "oversized") { process.stdout.write("x".repeat(8 * 1048576 + 2)); return; }
  const fields = frame.type === "start" ? { policyVersion: 1, ownership: "whole-store", successors: "source-bound-v1", isReviewAvailable: true } : { channel };
  process.stdout.write(JSON.stringify({ version: 1, invocationID: frame.invocationID, type: frame.type === "start" ? "ready" : "response", ...fields }) + "\\n");
 });
}
input(process.stdin, "stdin");
input(createReadStream(null, { fd: 3 }), "private");
`);
	await chmod(executable, 0o700);
	const previous = process.env.PI_CORE_MEMORIES_EXECUTABLE;
	process.env.PI_CORE_MEMORIES_EXECUTABLE = executable;
	try {
		const controller = new AbortController();
		const client = await openQueueClient(directory, controller.signal);
		await t.test("inventory survives the ordinary deadline but still expires at 120 seconds", async (t) => {
			t.mock.timers.enable({ apis: ["setTimeout"] });
			try {
				const inventory = client.request("inventory");
				t.mock.timers.tick(15_000);
				assert.equal((await inventory).channel, "stdin");
				const expired = assert.rejects(client.request("inventory", { isSilent: true }), /Native memory service stopped/);
				t.mock.timers.tick(119_999);
				assert.equal(client.signal?.aborted, false);
				t.mock.timers.tick(1);
				await expired;
				assert.equal(client.signal?.aborted, true);
			} finally { t.mock.timers.reset(); }
		});
		await client.close();
		await t.test("ordinary requests still expire at 15 seconds", async (t) => {
			const ordinary = await openQueueClient(directory, controller.signal);
			t.mock.timers.enable({ apis: ["setTimeout"] });
			try {
				const expired = assert.rejects(ordinary.request("presented", { isSilent: true }), /Native memory service stopped/);
				t.mock.timers.tick(14_999);
				assert.equal(ordinary.signal?.aborted, false);
				t.mock.timers.tick(1);
				await expired;
				assert.equal(ordinary.signal?.aborted, true);
			} finally { t.mock.timers.reset(); await ordinary.close(); }
		});
		const privateClient = await openQueueClient(directory, controller.signal);
		assert.equal((await privateClient.request("presented", {}, true)).channel, "private");
		await assert.rejects(privateClient.request("stderr"), (error: Error) => !error.message.includes("synthetic-private-marker"));
		await privateClient.close();
		const oversized = await openQueueClient(directory, new AbortController().signal);
		await assert.rejects(oversized.request("oversized"), /Native memory service stopped/);
		await oversized.close();
		const cancelled = await openQueueClient(directory, controller.signal);
		const interrupted = assert.rejects(cancelled.request("inventory", { isSilent: true }), /Native memory service stopped/);
		controller.abort();
		await interrupted;
		assert.equal(cancelled.signal?.aborted, true);
		await cancelled.close();
	} finally {
		if (previous === undefined) delete process.env.PI_CORE_MEMORIES_EXECUTABLE;
		else process.env.PI_CORE_MEMORIES_EXECUTABLE = previous;
		await rm(directory, { recursive: true, force: true });
	}
});
