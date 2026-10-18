import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";

import "./test/host.ts";
const { escapeReviewDetails, parseReviewFrame, registerReview } = await import("./review.ts");
const { Text } = await import("@earendil-works/pi-tui");

test("native preview preserves structural lines while escaping source controls", () => {
	const details = "Sources:\nsource\u001b[31m\u202e\r\nExact old bytes:\nold café\nExact final new bytes:\nnew 🌱";
	const rendered = new Text(escapeReviewDetails(details), 0, 0).render(100).map((line) => line.trimEnd()).join("\n");
	assert.match(rendered, /Sources:\nsource/);
	assert.match(rendered, /Exact old bytes:\nold café\nExact final new bytes:\nnew 🌱/);
	assert.ok(!rendered.includes("\\u{A}"));
	for (const escaped of ["\\u{1B}", "\\u{202E}", "\\u{D}"]) assert.ok(rendered.includes(escaped));
	for (const control of ["\u001b", "\u202e", "\r"]) assert.ok(!rendered.includes(control));
});

for (const status of ["approved", "detached"] as const) test(`saved ${status} entry retains known mutation and incomplete follow-up after queue failure`, async () => {
	let renderer!: (entry: { data: unknown }) => { render(width: number): string[] } | undefined;
	const shutdown = registerReview({
		registerCommand: () => {},
		registerEntryRenderer: (_type: string, callback: typeof renderer) => { renderer = callback; },
	} as unknown as ExtensionAPI);
	const commit = "c".repeat(40);
	const auditRef = `refs/memory-review/${status === "approved" ? "approvals" : "detach"}/${"a".repeat(64)}`;
	const operation = parseReviewFrame(Buffer.from(JSON.stringify({
		version: 1, type: "operation", invocationID: "fixture", status,
		candidateID: "b".repeat(64), commit, auditRef,
		reason: `${status} at ${commit}; follow-up persistence or recovery is incomplete: persistent outcome write failure`,
	})), "fixture");
	const saved = JSON.parse(JSON.stringify(operation));
	const text = renderer({ data: saved })!.render(400).map((line) => line.trimEnd()).join("\n");
	assert.match(text, new RegExp(`^Memory review: ${status}\\nCandidate:`));
	assert.ok(!text.includes("\\u{A}"));
	assert.ok(text.includes(`Memory review: ${status}`));
	assert.ok(text.includes(`Commit: ${commit}`));
	assert.ok(text.includes(`Audit: ${auditRef}`));
	assert.ok(text.includes("follow-up persistence or recovery is incomplete"));
	assert.ok(!text.includes("Commit: none"));
	await shutdown();
});

test("review frame parser refuses duplicate keys, foreign invocation, unknown fields and invalid UTF-8", () => {
	const good = { version: 1, type: "final", invocationID: "fixture", status: "completed", reason: null };
	assert.equal(parseReviewFrame(Buffer.from(JSON.stringify(good)), "fixture").type, "final");
	for (const bytes of [Buffer.from('{"version":1,"version":1}'), Buffer.from(JSON.stringify({ ...good, extra: true })), Buffer.from(JSON.stringify({ ...good, invocationID: "foreign" })), Buffer.from([0xc0, 0x80]), Buffer.alloc(8 * 1_048_576 + 1)]) {
		assert.throws(() => parseReviewFrame(bytes, "fixture"));
	}
});

test("non-terminal modes and command arguments cannot open native review or call a model", async () => {
	let handler!: (args: string, ctx: ExtensionCommandContext) => Promise<void>;
	const pi = { registerCommand: (name: string, command: { handler: typeof handler }) => { assert.equal(name, "mem-review"); handler = command.handler; }, registerEntryRenderer: () => {} } as unknown as ExtensionAPI;
	const shutdown = registerReview(pi);
	for (const [args, mode] of [["", "rpc"], ["", "json"], ["", "print"], ["approve", "tui"]]) {
		let notifications = 0;
		await handler(args, { mode, ui: { notify: () => notifications++, custom: () => assert.fail("Native UI forbidden") }, waitForIdle: () => assert.fail("Rejected before wait"), modelRegistry: new Proxy({}, { get: () => assert.fail("No model calls") }) } as unknown as ExtensionCommandContext);
		assert.equal(notifications, 1);
	}
	await shutdown();
});
