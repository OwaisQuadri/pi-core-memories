import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";
import { joinInteractiveMembership } from "./interactive-membership.ts";

async function waitFor(check: () => boolean): Promise<void> {
	for (let attempt = 0; attempt < 100; attempt++) { if (check()) return; await sleep(20); }
	assert.fail("Interactive membership did not converge.");
}

test("two processes share live IDs, foreground revokes background, and crash recovers without a lease timeout", async () => {
	const root = await mkdtemp("/private/tmp/pi-members-");
	const directory = join(root, "hosts");
	let controller = new AbortController(); let changes = 0;
	const local = await joinInteractiveMembership(directory, { sessionID: "one", isForeground: false }, () => { changes++; controller.abort(); });
	const script = `import { joinInteractiveMembership } from ${JSON.stringify(new URL("./interactive-membership.ts", import.meta.url).href)};
const member = await joinInteractiveMembership(process.argv[1], { sessionID: "two", isForeground: false }, () => {});
process.on("message", async (message) => { if (message === "foreground") { member.set({ sessionID: "two", isForeground: true }); process.send("updated"); } if (message === "close") { await member.close(); process.exit(0); } });
process.send("ready");`;
	const child = spawn(process.execPath, ["--input-type=module", "-e", script, directory], { stdio: ["ignore", "ignore", "pipe", "ipc"] });
	let isReady = false; child.on("message", (message) => { if (message === "ready") isReady = true; });
	const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
	try {
		await waitFor(() => isReady);
		assert.deepEqual((await local.snapshot()).sessionIDs, ["one", "two"]);
		await sleep(250); const before = changes; controller = new AbortController();
		child.send("foreground");
		await waitFor(() => changes > before);
		assert.equal(controller.signal.aborted, true);
		assert.equal((await local.snapshot()).isForeground, true);
		child.kill("SIGKILL"); await exited;
		assert.deepEqual(await local.snapshot(), { sessionIDs: ["one"], isForeground: false });
		await writeFile(join(directory, "foreign.json"), "{}", { mode: 0o600 });
		await assert.rejects(local.snapshot(), /unavailable or ambiguous/);
	} finally { child.kill("SIGKILL"); await local.close(); await rm(root, { recursive: true, force: true }); }
});

test("unsafe shared directory permissions fail closed without changing them", async () => {
	const root = await mkdtemp("/private/tmp/pi-members-unsafe-");
	try {
		const { mkdir, chmod, stat } = await import("node:fs/promises");
		const directory = join(root, "hosts"); await mkdir(directory); await chmod(directory, 0o755);
		await assert.rejects(joinInteractiveMembership(directory, { sessionID: "one", isForeground: false }, () => {}), /unavailable or ambiguous/);
		assert.equal((await stat(directory)).mode & 0o777, 0o755);
	} finally { await rm(root, { recursive: true, force: true }); }
});

test("a refused socket with a live PID stays ambiguous and is never pruned", async () => {
	const root = await mkdtemp("/private/tmp/pi-members-live-"); const directory = join(root, "hosts");
	const local = await joinInteractiveMembership(directory, { sessionID: "one", isForeground: false }, () => {});
	try {
		const { createServer } = await import("node:net"); const { rename, lstat, chmod } = await import("node:fs/promises"); const { randomUUID } = await import("node:crypto");
		const original = join(root, "endpoint"); const refused = join(directory, `${process.pid}-${randomUUID()}.sock`);
		const server = createServer(); await new Promise<void>((resolve) => server.listen(original, resolve));
		await rename(original, refused); await new Promise<void>((resolve) => server.close(() => resolve())); await chmod(refused, 0o600);
		await assert.rejects(local.snapshot(), /unavailable or ambiguous/); assert.equal((await lstat(refused)).isSocket(), true);
	} finally { await local.close(); await rm(root, { recursive: true, force: true }); }
});
