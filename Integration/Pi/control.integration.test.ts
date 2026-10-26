import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";

import { sdkRoot } from "./test/host.ts";

test("real Pi RPC handshake uses its absolute worker without PATH lookup or a model call", { timeout: 30_000 }, async (t) => {
	const binary = process.env.PI_CORE_MEMORIES_BIN;
	assert.ok(binary, "Set PI_CORE_MEMORIES_BIN to the verified memory command");
	const root = await mkdtemp("/private/tmp/memory-control-rpc-");
	t.after(() => rm(root, { recursive: true, force: true }));
	const home = join(root, "home");
	const agent = join(home, "agent");
	const sessions = join(agent, "sessions");
	const memory = join(root, "memory");
	await mkdir(sessions, { recursive: true });
	execFileSync(binary, ["init", "--repo", memory]);
	const provider = join(root, "provider.ts");
	await writeFile(provider, `export default function(pi) {
		pi.registerProvider("memory-control-fixture", {
			api: "memory-control-fixture", apiKey: "fixture-only", baseUrl: "https://example.invalid",
			models: [{ id: "offline", name: "Offline fixture", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 8192 }],
			streamSimple() { throw new Error("Model calls are forbidden in this fixture"); }
		});
	}`);
	const child = spawn(process.execPath, [join(sdkRoot, "dist/cli.js"), "--offline", "--mode", "rpc", "--no-session", "--no-extensions", "--extension", resolve(import.meta.dirname, "control.ts"), "--extension", resolve(import.meta.dirname, "test/source-protection.ts"), "--extension", provider, "--no-mcp", "--no-tools", "--no-skills", "--no-prompt-templates", "--no-context-files", "--provider", "memory-control-fixture", "--model", "offline", "--models", "memory-control-fixture/offline", "--thinking", "off"], {
		cwd: root,
		env: { ...process.env, HOME: home, PI_CODING_AGENT_DIR: agent, PI_CORE_MEMORIES_DREAM_EXECUTABLE: resolve(binary), PATH: "/usr/bin:/bin" },
		stdio: "pipe",
	});
	t.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
	const events: Record<string, unknown>[] = [];
	let stderr = "";
	child.stderr.on("data", (chunk) => { stderr += chunk; });
	const lines = createInterface({ input: child.stdout });
	const result = await new Promise<Record<string, unknown>>((done, fail) => {
		let final: Record<string, unknown> | undefined;
		let isPromptComplete = false;
		child.on("error", fail);
		child.on("close", (code) => {
			lines.close();
			if (code !== 0 || !final || !isPromptComplete) fail(new Error(`Incomplete RPC fixture: ${code}; ${stderr}`));
			else done(final);
		});
		lines.on("line", (line) => {
			try {
				const event = JSON.parse(line);
				if (event.type === "extension_ui_request" && event.method === "notify") {
					const notification = JSON.parse(event.message);
					events.push(notification);
					if (notification.event === "report") final = notification.report;
					if (notification.event === "error") throw new Error(notification.detail);
				}
				if (event.type === "response" && event.id === "commands") {
					assert.equal(event.success, true);
					assert.ok(event.data.commands.some((command: { name: string }) => command.name === "memory-dream-control"));
					const request = { operation: "start", roots: { state: join(root, "state"), sessions, memory, snippets: null, prompts: null, globalAgents: null } };
					child.stdin.write(JSON.stringify({ id: "run", type: "prompt", message: `/memory-dream-control ${JSON.stringify(request)}` }) + "\n");
				}
				if (event.type === "response" && event.id === "run") {
					assert.equal(event.success, true);
					isPromptComplete = true;
					child.stdin.end();
				}
			} catch (error) { child.stdin.end(); child.kill("SIGTERM"); fail(error); }
		});
		child.stdin.write(JSON.stringify({ id: "commands", type: "get_commands" }) + "\n");
	});
	assert.equal(result.status, "noNewRecords");
	assert.equal(stderr, "");
	assert.ok(!events.some((event) => event.phase === "modelCall"));
	assert.deepEqual(events.find((event) => event.event === "selection")?.selection, { provider: "memory-control-fixture", modelID: "offline", thinkingLevel: "off" });
});
