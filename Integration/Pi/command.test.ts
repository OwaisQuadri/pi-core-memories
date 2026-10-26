import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
	writeFileSync(join(source, "Package.swift"), '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Fixture", products: [.executable(name: "pi-core-memories", targets: ["Fixture"])], targets: [.executableTarget(name: "Fixture", path: "Sources")])\n');
	writeFileSync(join(source, "Sources/input.swift"), '@main struct Fixture { static func main() { print("fixture", terminator: "") } }\n');
	writeFileSync(join(source, "build.zsh"), `if [[ -f target/fail ]]; then exit 17; fi\n${readFileSync(new URL("../../build.zsh", import.meta.url), "utf8")}\nprint built >> target/count\n`);
	for (const args of [["init", "-q", "-b", "fixture"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]]) execFileSync("git", ["-C", source, ...args]);
	execFileSync("git", ["clone", "-q", source, installed]);
	symlinkSync(realpathSync(new URL("../../node_modules", import.meta.url)), join(installed, "node_modules"));
	mkdirSync(join(installed, "target/build"), { recursive: true });
	writeFileSync(join(installed, "target/build/.lock"), "fixture\n");
	return installed;
}

test("session builds accept an existing SwiftPM lock, clean generated output before stamping and retain output on refusal", async (t) => {
	const root = fixture(t);
	const command: typeof import("./command.ts") = await import(pathToFileURL(join(root, "Integration/Pi/command.ts")).href);
	const previous = process.env.PI_CORE_MEMORIES_EXECUTABLE;
	delete process.env.PI_CORE_MEMORIES_EXECUTABLE;
	t.after(() => { if (previous === undefined) delete process.env.PI_CORE_MEMORIES_EXECUTABLE; else process.env.PI_CORE_MEMORIES_EXECUTABLE = previous; });
	const messages: string[] = [];
	const ctx = { hasUI: true, ui: { setWidget: (_name: string, lines: string[]) => messages.push(...lines) } } as unknown as ExtensionContext;
	await command.buildCommand(ctx);
	assert.equal(existsSync(join(root, "target/count")), true, messages.join("\n"));
	assert.equal(readFileSync(join(root, "target/count"), "utf8"), "built\n");
	assert.equal(existsSync(join(root, "target/build/release")), false);
	mkdirSync(join(root, "target/build"), { recursive: true });
	writeFileSync(join(root, "target/build/.lock"), "retained lock\n");
	assert.equal(await isBuildNeeded(command.commandBuild), false);
	await command.buildCommand(ctx);
	assert.equal(readFileSync(join(root, "target/build/.lock"), "utf8"), "retained lock\n");
	assert.equal(readFileSync(join(root, "target/count"), "utf8"), "built\n");
	rmSync(stampPath(command.commandBuild));
	await command.buildCommand(ctx);
	assert.equal(readFileSync(join(root, "target/count"), "utf8"), "built\nbuilt\n");
	assert.equal(existsSync(join(root, "target/build/release")), false);
	const output = readFileSync(command.commandPath());
	const stamp = readFileSync(stampPath(command.commandBuild));
	writeFileSync(join(root, "Sources/input.swift"), "dirty\n");
	await command.buildCommand(ctx);
	assert.match(messages.at(-1)!, /not built:.*Refused/);
	assert.deepEqual(readFileSync(command.commandPath()), output);
	assert.deepEqual(readFileSync(stampPath(command.commandBuild)), stamp);
});

test("native cleanup refuses redirected scratch without changing the external directory", (t) => {
	for (const relative of ["target", "target/build"]) {
		const root = fixture(t);
		const outside = join(root, "../outside");
		mkdirSync(outside);
		writeFileSync(join(outside, "sentinel"), "retained\n");
		rmSync(join(root, relative), { recursive: true });
		symlinkSync(outside, join(root, relative));
		const refused = spawnSync("/bin/zsh", ["-f", "build.zsh"], { cwd: root, encoding: "utf8", timeout: 20_000 });
		assert.ifError(refused.error);
		assert.notEqual(refused.status, 0);
		assert.match(refused.stderr, /Refused symlinked/);
		assert.deepEqual(readdirSync(outside), ["sentinel"]);
		assert.equal(readFileSync(join(outside, "sentinel"), "utf8"), "retained\n");
	}
});

test("install argv ignores the session executable override, propagates failure and waits for adopted compilation and cleanup", (t) => {
	const root = fixture(t);
	const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { pi: { compile: string[] } };
	const [executable, ...args] = manifest.pi.compile;
	assert.equal(executable, "node");
	const options = { cwd: root, env: { ...process.env, PI_CORE_MEMORIES_EXECUTABLE: "/usr/bin/true" }, encoding: "utf8" as const, timeout: 20_000 };
	mkdirSync(join(root, "target"), { recursive: true });
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
	assert.equal(existsSync(join(root, "target/build/release")), false);
	const output = readFileSync(join(root, "target/release/pi-core-memories"));
	const stamp = readFileSync(join(root, "target/release/pi-core-memories.stamp"));
	rmSync(join(root, ".git"), { recursive: true });
	const unverified = spawnSync(executable!, args, options);
	assert.ifError(unverified.error);
	assert.notEqual(unverified.status, 0);
	assert.match(unverified.stderr, /refused/i);
	assert.deepEqual(readFileSync(join(root, "target/release/pi-core-memories")), output);
	assert.deepEqual(readFileSync(join(root, "target/release/pi-core-memories.stamp")), stamp);
});
