import { registerHooks } from "node:module";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const sdkRoot = process.env.PI_PACKAGE_ROOT ?? fileURLToPath(new URL("../", import.meta.resolve("@earendil-works/pi-coding-agent")));
export const sdkURL = pathToFileURL(join(sdkRoot, "dist/index.js")).href;
registerHooks({ resolve(specifier, context, next) {
	if (specifier === "@earendil-works/pi-coding-agent") return { url: sdkURL, shortCircuit: true };
	if (specifier === "@earendil-works/pi-ai" || specifier === "@earendil-works/pi-tui") return next(specifier, { ...context, parentURL: sdkURL });
	return next(specifier, context);
} });
export const aiURL = import.meta.resolve("@earendil-works/pi-ai");
export const tuiURL = import.meta.resolve("@earendil-works/pi-tui");
