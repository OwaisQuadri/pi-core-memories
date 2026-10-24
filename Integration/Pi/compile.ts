import { ensureBuilt } from "pi-compiled";
import { commandBuild } from "./command.ts";

await ensureBuilt({ ...commandBuild, overrideEnv: undefined, isGitVerificationRequired: true });
