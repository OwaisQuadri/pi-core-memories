import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { binaryPath, ensureBuilt, isBuildNeeded, type BuildSpec } from "pi-compiled";

export const commandBuild: BuildSpec = {
	packageRoot: fileURLToPath(new URL("../..", import.meta.url)),
	binary: "target/release/pi-core-memories",
	buildCommand: ["/bin/zsh", "-f", "build.zsh"],
	inputs: ["Package*.swift", "Sources", "build.zsh"],
	overrideEnv: "PI_CORE_MEMORIES_EXECUTABLE",
	isUpstreamRequired: true,
};

export function commandPath(): string {
	return binaryPath(commandBuild);
}

let building: Promise<void> = Promise.resolve();

export function isCommandMissing(): boolean {
	return !existsSync(commandPath());
}

export function commandReady(): Promise<void> {
	return isCommandMissing() ? building : Promise.resolve();
}

export function buildCommand(ctx: ExtensionContext): Promise<void> {
	building = build(ctx);
	return building;
}

async function build(ctx: ExtensionContext): Promise<void> {
	try {
		if (!(await isBuildNeeded(commandBuild))) return;
		ctx.ui.notify("pi-core-memories is building its command.", "info");
		await ensureBuilt(commandBuild);
		ctx.ui.notify("pi-core-memories built its command.", "info");
	} catch (error) {
		ctx.ui.notify(`pi-core-memories could not build its command: ${(error as Error).message}`, "warning");
	}
}
