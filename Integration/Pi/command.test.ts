import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";

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
