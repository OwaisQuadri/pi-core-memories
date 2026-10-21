import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { binaryPath, ensureBuilt, isBuildNeeded, progressBar, type BuildSpec } from "pi-compiled";

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

export function commandReady(signal?: AbortSignal): Promise<void> {
	if (!isCommandMissing()) return Promise.resolve();
	if (!signal) return building;
	return new Promise((done, fail) => {
		const abort = () => fail(signal.reason);
		if (signal.aborted) return abort();
		signal.addEventListener("abort", abort, { once: true });
		void building.then(() => {
			signal.removeEventListener("abort", abort);
			done();
		});
	});
}

export function buildCommand(ctx: ExtensionContext): Promise<void> {
	building = build(ctx);
	return building;
}

async function build(ctx: ExtensionContext): Promise<void> {
	try {
		if (!(await isBuildNeeded(commandBuild))) return;
		const show = (text?: string) => { if (ctx.hasUI) ctx.ui.setWidget("pi-core-memories-build", text === undefined ? undefined : [`pi-core-memories command: ${text}`]); };
		show("starting the build");
		try {
			await ensureBuilt(commandBuild, { onProgress: (progress) => show(progressBar(progress)) });
		} finally {
			show();
		}
		ctx.ui.notify("pi-core-memories built its command.", "info");
	} catch (error) {
		ctx.ui.notify(`pi-core-memories could not build its command: ${(error as Error).message}`, "warning");
	}
}
