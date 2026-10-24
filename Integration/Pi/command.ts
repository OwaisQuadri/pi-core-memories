import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { binaryPath, ensureBuilt, progressBar, type BuildSpec } from "pi-compiled";

export const commandBuild: BuildSpec = {
	packageRoot: fileURLToPath(new URL("../..", import.meta.url)),
	binary: "target/release/pi-core-memories",
	buildCommand: ["/bin/zsh", "-f", "build.zsh"],
	inputs: ["Package*.swift", "Sources", "build.zsh"],
	cleanupPaths: ["target/build"],
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

export function clearBuildResult(ctx: ExtensionContext): void {
	try { if (ctx.hasUI) ctx.ui.setWidget("pi-core-memories-build", undefined); } catch {}
}

async function build(ctx: ExtensionContext): Promise<void> {
	const show = (text: string) => { try { if (ctx.hasUI) ctx.ui.setWidget("pi-core-memories-build", [`pi-core-memories command: ${text}`]); } catch {} };
	try {
		show("starting the build");
		await ensureBuilt(commandBuild, { onProgress: (progress) => show(progressBar(progress)) });
		show("built. Memory tools use it now.");
	} catch (error) {
		show(`not built: ${(error as Error).message}`);
	}
}
