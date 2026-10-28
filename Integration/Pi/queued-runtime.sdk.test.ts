import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { AgentSession, ExtensionContext, ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { aiURL, sdkURL } from "./test/host.ts";
import { registerQueuedRuntime } from "./queued-runtime.ts";

const sdk = await import(sdkURL) as typeof import("@earendil-works/pi-coding-agent");
const ai = await import(aiURL) as typeof import("@earendil-works/pi-ai");

test("public SDK session delivers a proposal and binds the later ordinary reply", async () => {
	const root = await mkdtemp(join(tmpdir(), "memory-public-sdk-"));
	let session: AgentSession | undefined;
	let ui: ExtensionContext["ui"] | undefined;
	let stop: (() => Promise<void>) | undefined;
	const frames: { type: string; fields: Record<string, unknown>; isPrivate?: boolean }[] = [];
	let digest = "";
	const revision = "a".repeat(64);
	const factory: ExtensionFactory = (pi) => {
		pi.on("session_start", (_event, ctx) => { ui = ctx.ui; });
		stop = registerQueuedRuntime(pi, {
			idleMilliseconds: 3_600_000,
			run: async () => assert.fail("This fixture must not call a background model."),
			roots: async () => ({ state: join(root, "state"), sessions: join(root, "sessions"), memory: join(root, "memory"), snippets: null, prompts: null, globalAgents: null }),
			scope: async () => ({}),
			membership: async () => ({ set: () => {}, snapshot: async () => ({ sessionIDs: [], isForeground: false }), close: async () => {} }),
			open: async (_directory, signal) => ({
				signal,
				request: async (type, fields = {}, isPrivate) => {
					frames.push({ type, fields, isPrivate });
					if (type === "claim") {
						const presentation = { claimID: "sdk-claim", sequence: "1", request: { sessionID: fields.sessionID, requestID: fields.requestID }, isDetachRequired: false, previewDigest: "d".repeat(64), finding: { candidateID: "c".repeat(64), revision, operation: "add" } };
						const bytes = Buffer.from(JSON.stringify(presentation));
						digest = createHash("sha256").update(bytes).digest("hex");
						return { type: "presentation", display: { presentation, displayDigest: digest }, displayBytes: bytes.toString("base64") };
					}
					if (type === "presented") return { type, displayDigest: digest };
					if (type === "reply") return { type: "decision", receipt: { decisionID: fields.decisionID, revision, displayDigest: digest, status: "approved", commit: "f".repeat(40), auditRef: "refs/core-memories/sdk-fixture" } };
					return { type: "released" };
				},
				close: async () => {},
			}),
		});
	};
	try {
		const settingsManager = sdk.SettingsManager.inMemory({ cacheWarming: "off", compaction: { enabled: false } });
		const resourceLoader = new sdk.DefaultResourceLoader({ cwd: root, agentDir: root, settingsManager, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true, extensionFactories: [factory] });
		await resourceLoader.reload();
		assert.deepEqual(resourceLoader.getExtensions().errors, []);
		const modelRuntime = await sdk.ModelRuntime.create({ authPath: join(root, "synthetic-credentials.json"), modelsPath: null, modelsStorePath: join(root, "synthetic-models.json"), allowModelNetwork: false, refreshOnCreate: false });
		await modelRuntime.setRuntimeApiKey("openai", "synthetic-offline-key");
		const model = modelRuntime.getModels("openai")[0];
		assert.ok(model);
		({ session } = await sdk.createAgentSession({ cwd: root, agentDir: root, modelRuntime, model, thinkingLevel: "off", tools: ["memory_queue"], resourceLoader, settingsManager, sessionManager: sdk.SessionManager.inMemory(root) }));
		let calls = 0;
		session.agent.streamFunction = (_model, context) => {
			assert.ok(!JSON.stringify(context).includes("sdk-claim"), "Native proposal control data entered model context.");
			const index = calls++;
			assert.ok(index < 4, "Unexpected extra model step.");
			const message: AssistantMessage = { role: "assistant", api: model.api, provider: model.provider, model: model.id, content: index === 0 || index === 2 ? [{ type: "toolCall", id: `sdk-call-${index}`, name: "memory_queue", arguments: index === 0 ? { operation: "present", revision } : { operation: "reply" } }] : [{ type: "text", text: "Synthetic conversation turn complete." }], stopReason: index === 0 || index === 2 ? "toolUse" : "stop", timestamp: 0, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
			const stream = ai.createAssistantMessageEventStream();
			queueMicrotask(() => { stream.push({ type: "done", reason: message.stopReason as "toolUse" | "stop", message }); stream.end(); });
			return stream;
		};
		const errors: string[] = [];
		await session.bindExtensions({ mode: "tui", onError: (error) => { errors.push(error.error); } });
		assert.ok(ui);
		await session.bindExtensions({ mode: "tui", uiContext: { ...ui, custom: async () => assert.fail("A memory proposal must not open a modal.") } });
		await session.prompt("Suggest a synthetic memory.", { source: "interactive", expandPromptTemplates: false });
		const proposal = session.sessionManager.getBranch().find((entry) => entry.type === "custom_message" && entry.customType === "pi-core-memories:proposal");
		assert.ok(proposal, JSON.stringify({ calls, errors, frames, tools: session.getActiveToolNames(), branch: session.sessionManager.getBranch() }));
		assert.equal(frames.filter((frame) => frame.type === "claim").length, 1);
		assert.equal(frames.filter((frame) => frame.type === "reply").length, 0);
		await session.prompt("save that memory", { source: "interactive", expandPromptTemplates: false });
		assert.equal(calls, 4);
		assert.deepEqual(errors, []);
		const acknowledgement = frames.find((frame) => frame.type === "presented");
		const reply = frames.find((frame) => frame.type === "reply");
		assert.ok(acknowledgement);
		assert.ok(reply);
		assert.equal(acknowledgement.isPrivate, true);
		assert.equal(reply.isPrivate, true);
		assert.equal(reply.fields.originalText, "save that memory");
		assert.equal(reply.fields.submittedText, "save that memory");
		assert.equal(frames.filter((frame) => frame.type === "claim").length, 1);
	} finally {
		await stop?.();
		session?.dispose();
		await rm(root, { recursive: true, force: true });
	}
});
