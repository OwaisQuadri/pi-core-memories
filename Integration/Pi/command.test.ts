import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { pathToFileURL } from "node:url";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isBuildNeeded, stampPath } from "pi-compiled";

function fixture(t: TestContext): string {
	const root = mkdtempSync(join(tmpdir(), "pi-native-compile-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const source = join(root, "source");
	const installed = join(root, "installed");
	mkdirSync(join(source, "Integration/Pi"), { recursive: true });
	mkdirSync(join(source, "Sources"));
	for (const name of ["command.ts", "compile.ts"]) copyFileSync(new URL(name, import.meta.url), join(source, "Integration/Pi", name));
	copyFileSync(new URL("../../package.json", import.meta.url), join(source, "package.json"));
	writeFileSync(join(source, ".gitignore"), "target/\nnode_modules/\n");
	writeFileSync(join(source, "Package.swift"), "fixture\n");
	writeFileSync(join(source, "Sources/input.swift"), "fixture\n");
	writeFileSync(join(source, "build.zsh"), "set -eu\nmkdir -p target/build\nprint scratch > target/build/object\nif [[ -f target/fail ]]; then exit 17; fi\nmkdir -p target/release\nprint '#!/bin/sh' > target/release/pi-core-memories\nprint 'printf fixture' >> target/release/pi-core-memories\nchmod +x target/release/pi-core-memories\nprint built >> target/count\n");
	for (const args of [["init", "-q", "-b", "fixture"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]]) execFileSync("git", ["-C", source, ...args]);
	execFileSync("git", ["clone", "-q", source, installed]);
	symlinkSync(realpathSync(new URL("../../node_modules", import.meta.url)), join(installed, "node_modules"));
	return installed;
}

test("session build retries pending scratch cleanup at a matching stamp without rebuilding and retains output on refusal", async (t) => {
	const root = fixture(t);
	const command: typeof import("./command.ts") = await import(pathToFileURL(join(root, "Integration/Pi/command.ts")).href);
	const previous = process.env.PI_CORE_MEMORIES_EXECUTABLE;
	delete process.env.PI_CORE_MEMORIES_EXECUTABLE;
	t.after(() => { if (previous === undefined) delete process.env.PI_CORE_MEMORIES_EXECUTABLE; else process.env.PI_CORE_MEMORIES_EXECUTABLE = previous; });
	const messages: string[] = [];
	const ctx = { hasUI: true, ui: { setWidget: (_name: string, lines: string[]) => messages.push(...lines) } } as unknown as ExtensionContext;
	await command.buildCommand(ctx);
	assert.equal(readFileSync(join(root, "target/count"), "utf8"), "built\n");
	const output = readFileSync(command.commandPath());
	const stamp = readFileSync(stampPath(command.commandBuild));
	mkdirSync(join(root, "target/build"));
	writeFileSync(join(root, "target/build/pending"), "scratch");
	assert.equal(await isBuildNeeded(command.commandBuild), false);
	await command.buildCommand(ctx);
	assert.equal(existsSync(join(root, "target/build")), false);
	assert.equal(readFileSync(join(root, "target/count"), "utf8"), "built\n");
	writeFileSync(join(root, "Sources/input.swift"), "dirty\n");
	await command.buildCommand(ctx);
	assert.match(messages.at(-1)!, /not built:.*Refused/);
	assert.deepEqual(readFileSync(command.commandPath()), output);
	assert.deepEqual(readFileSync(stampPath(command.commandBuild)), stamp);
});

test("install argv ignores the session executable override, propagates failure and waits for adopted compilation and cleanup", (t) => {
	const root = fixture(t);
	const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { pi: { compile: string[] } };
	const [executable, ...args] = manifest.pi.compile;
	assert.equal(executable, "node");
	const options = { cwd: root, env: { ...process.env, PI_CORE_MEMORIES_EXECUTABLE: "/usr/bin/true" }, encoding: "utf8" as const, timeout: 20_000 };
	mkdirSync(join(root, "target"));
	writeFileSync(join(root, "target/fail"), "fail");
	const failed = spawnSync(executable!, args, options);
	assert.ifError(failed.error);
	assert.notEqual(failed.status, 0);
	assert.match(failed.stderr, /build failed/i);
	assert.equal(existsSync(join(root, "target/release/pi-core-memories.stamp")), false);
	rmSync(join(root, "target/fail"));
	const built = spawnSync(executable!, args, options);
	assert.ifError(built.error);
	assert.equal(built.status, 0, built.stderr);
	assert.equal(execFileSync(join(root, "target/release/pi-core-memories"), { encoding: "utf8" }), "fixture");
	assert.equal(existsSync(join(root, "target/release/pi-core-memories.stamp")), true);
	assert.equal(existsSync(join(root, "target/build")), false);
});
