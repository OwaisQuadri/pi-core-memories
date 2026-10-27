import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";

test("shipped memory extension sources contain no commands or manual review mode", async () => {
	const files = await readdir(import.meta.dirname);
	for (const file of files.filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts"))) {
		const source = await readFile(join(import.meta.dirname, file), "utf8");
		assert.doesNotMatch(source, /\bregisterCommand\s*\(/, file);
		assert.doesNotMatch(source, /memory-queue-review-config/, file);
		assert.doesNotMatch(source, /askMemoryDecision|ask-user-question:rpc:ask/, file);
	}
	for (const file of ["control.ts", "review.ts", "approved-review.ts", "conversation.ts"]) {
		await assert.rejects(readFile(join(import.meta.dirname, file)), { code: "ENOENT" });
	}
});
