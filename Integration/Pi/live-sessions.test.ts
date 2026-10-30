import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { liveSessionIDs, markLiveSession } from "./live-sessions.ts";

test("another process's live session is excluded until it exits, then its stale marker is pruned", async () => {
	const root = await mkdtemp("/private/tmp/pi-live-");
	const directory = join(root, "hosts");
	const local = await markLiveSession(directory, "one");
	const script = `import { markLiveSession } from ${JSON.stringify(new URL("./live-sessions.ts", import.meta.url).href)};
await markLiveSession(process.argv[1], "two"); process.send("ready"); setInterval(() => {}, 1000);`;
	const child = spawn(process.execPath, ["--input-type=module", "-e", script, directory], { stdio: ["ignore", "ignore", "pipe", "ipc"] });
	const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
	try {
		await new Promise<void>((resolve) => child.once("message", () => resolve()));
		assert.deepEqual(await liveSessionIDs(directory), ["one", "two"]);
		child.kill("SIGKILL"); await exited;
		assert.deepEqual(await liveSessionIDs(directory), ["one"]);
		assert.equal((await readdir(directory)).length, 1);
		await local.close();
		assert.deepEqual(await liveSessionIDs(directory), []);
	} finally { child.kill("SIGKILL"); await local.close(); await rm(root, { recursive: true, force: true }); }
});

test("unsafe shared directory permissions fail closed without changing them", async () => {
	const root = await mkdtemp("/private/tmp/pi-live-unsafe-");
	try {
		const directory = join(root, "hosts"); await mkdir(directory); await chmod(directory, 0o755);
		await assert.rejects(markLiveSession(directory, "one"), /unavailable or unsafe/);
		await assert.rejects(liveSessionIDs(directory), /unavailable or unsafe/);
		assert.equal((await stat(directory)).mode & 0o777, 0o755);
	} finally { await rm(root, { recursive: true, force: true }); }
});
