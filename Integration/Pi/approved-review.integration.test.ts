import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, symlink, rm, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";

import "./test/host.ts";
const { registerMemoryManagement } = await import("./management.ts");
const binary = process.env.PI_CORE_MEMORIES_BIN;
assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the checked command");

async function waitFor(check: () => boolean): Promise<void> {
	const deadline = Date.now() + 7000;
	while (!check()) { assert.ok(Date.now() < deadline, "Native entry review deadline"); await new Promise((done) => setTimeout(done, 10)); }
}

test("native approved review works without dream; Back and Defer preserve dates, explicit Confirm changes metadata only", { timeout: 30000 }, async (t) => {
	const root = await mkdtemp("/private/tmp/pi-approved-review-");
	const repo = join(root, "memory"); const bin = join(root, "bin"); const home = join(root, "home");
	const previous = Object.fromEntries(["HOME", "PI_CORE_MEMORIES_EXECUTABLE", "PI_CORE_MEMORIES_REPO"].map((name) => [name, process.env[name]]));
	t.after(async () => { for (const [name, value] of Object.entries(previous)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; } await rm(root, { recursive: true, force: true }); });
	await mkdir(home);
	process.env.HOME = home; process.env.PI_CORE_MEMORIES_EXECUTABLE = resolve(binary!); process.env.PI_CORE_MEMORIES_REPO = repo;
	const cli = (args: string[], input?: object) => execFileSync(binary!, args, { input: input ? JSON.stringify(input) : undefined, encoding: "utf8" });
	const git = (...args: string[]) => execFileSync("/usr/bin/git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
	cli(["init", "--repo", repo]); git("checkout", "--detach");
	let base = git("rev-parse", "main");
	for (const text of ["Exact café 🌱.", "Sibling stays."]) {
		const receipt = JSON.parse(cli(["manage", "--repo", repo], { operation: "add", base, path: "MEMORY.md", replacement: `${text} [source: stored-reference; added: 2026-01-01]\n`, reason: "User requested entry" }));
		base = receipt.commit;
	}
	const original = JSON.parse(cli(["review-catalog", "--repo", repo, "--cwd", root]));
	assert.equal(original.catalog.entries.length, 2); assert.deepEqual(original.due, [0, 1]);
	const index = await readFile(join(repo, ".git", "index")); const file = await readFile(join(repo, "MEMORY.md")); const head = git("rev-parse", "HEAD");
	const commands = new Map<string, (args: string, ctx: ExtensionCommandContext) => Promise<void>>();
	const shutdown = registerMemoryManagement({ registerTool: () => {}, registerCommand: (name: string, value: { handler: (args: string, ctx: ExtensionCommandContext) => Promise<void> }) => commands.set(name, value.handler) } as unknown as ExtensionAPI);
	try {
		for (const moves of [0, 1, 2]) {
			let component: Component | undefined;
			const notices: string[] = [];
			const ctx = { cwd: root, mode: "tui", hasUI: true, waitForIdle: async () => {}, ui: {
				select: async (_title: string, choices: string[]) => choices[1],
				notify: (message: string) => notices.push(message),
				custom: (factory: (...args: unknown[]) => unknown) => new Promise<string>((done) => { component = factory({ terminal: { rows: 32 }, requestRender: () => {} }, { fg: (_name: string, text: string) => text }, {}, done) as Component; }),
			} } as unknown as ExtensionCommandContext;
			const completion = commands.get("mem-rereview")!("", ctx);
			await waitFor(() => !!component);
			const screen = component!.render(100).join("\n");
			assert.match(screen, /Exact café 🌱/); assert.match(screen, /Stored sources are unverified references/);
			assert.match(screen, /Reviewed: unknown/); assert.match(screen, /Confirm reviewed/);
			for (let move = 0; move < moves; move++) component!.handleInput!("\u001b[B");
			component!.handleInput!("\r"); await completion;
			assert.equal(notices.length, 1);
			if (moves < 2) { assert.equal(git("rev-parse", "main"), base); assert.match(notices[0], /unchanged/); }
		}
		const final = JSON.parse(cli(["review-catalog", "--repo", repo, "--cwd", root]));
		assert.deepEqual(final.due, [1]);
		assert.equal(final.catalog.entries[1].expected, original.catalog.entries[1].expected);
		const old = original.catalog.entries[0]; const reviewed = final.catalog.entries[0];
		assert.equal(reviewed.identity, old.identity); assert.equal(reviewed.revised, old.revised);
		assert.equal(reviewed.expected.replace(`; reviewed: ${reviewed.reviewed}`, ""), old.expected);
		assert.equal(git("rev-parse", "HEAD"), head);
		assert.deepEqual(await readFile(join(repo, ".git", "index")), index); assert.deepEqual(await readFile(join(repo, "MEMORY.md")), file);
	} finally { await shutdown(); }
});
