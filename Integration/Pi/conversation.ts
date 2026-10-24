import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export type MemoryConversationPreview = {
	candidateID: string;
	digest: string;
	details: string;
};
export type MemoryConversationChoice = "approve" | "reject" | "defer" | "cancelled";

export async function askMemoryDecision(
	pi: ExtensionAPI,
	ctx: ExtensionContext,
	preview: MemoryConversationPreview,
	signal: AbortSignal,
	isCurrent: () => boolean,
): Promise<MemoryConversationChoice> {
	if (signal.aborted || !isCurrent()) return "cancelled";
	if (ctx.mode !== "tui" || !ctx.hasUI) throw new Error("Memory approval requires an interactive Pi session.");
	if (!/^[a-f0-9]{64}$/.test(preview.candidateID) || !/^[a-f0-9]{64}$/.test(preview.digest)
		|| !preview.details.trim() || Buffer.byteLength(preview.details) > 64 * 1024
		|| /[\x00-\x08\x0b-\x1f\x7f-\x9f]/u.test(preview.details)) {
		throw new Error("The exact memory proposal cannot be safely shown. Nothing was approved.");
	}
	const sessionID = ctx.sessionManager.getSessionId();
	const requestID = randomUUID();
	const pingChannel = "ask-user-question:rpc:ping";
	const isAvailable = await new Promise<boolean>((resolve) => {
		const finish = (isAvailable: boolean) => {
			clearTimeout(timer);
			off();
			signal.removeEventListener("abort", abort);
			resolve(isAvailable);
		};
		const abort = () => finish(false);
		const off = pi.events.on(`${pingChannel}:reply:${requestID}`, (payload) => {
			const reply = payload as { success?: unknown; data?: { version?: unknown } } | null;
			finish(reply?.success === true && reply.data?.version === 1);
		});
		const timer = setTimeout(() => finish(false), 5000);
		signal.addEventListener("abort", abort, { once: true });
		if (signal.aborted) abort();
		else pi.events.emit(pingChannel, { requestId: requestID });
	});
	if (signal.aborted || !isCurrent() || ctx.sessionManager.getSessionId() !== sessionID) return "cancelled";
	if (!isAvailable) throw new Error("The Pi question service is unavailable. Nothing was approved.");
	const question = "Save this exact finding to approved memory?";
	const details = `${preview.details.trim()}\n\nProposal: ${preview.candidateID}\nExact version: ${preview.digest}`;
	const channel = "ask-user-question:rpc:ask";
	return new Promise<MemoryConversationChoice>((resolve, reject) => {
		let isFinished = false;
		const finish = (choice: MemoryConversationChoice, error?: Error) => {
			if (isFinished) return;
			isFinished = true;
			off();
			signal.removeEventListener("abort", abort);
			if (error) reject(error);
			else resolve(choice);
		};
		const abort = () => finish("cancelled");
		const off = pi.events.on(`${channel}:reply:${requestID}`, (payload) => {
			if (signal.aborted || !isCurrent() || ctx.sessionManager.getSessionId() !== sessionID) return finish("cancelled");
			const reply = payload as { success?: unknown; data?: { isError?: unknown; details?: {
				status?: unknown; provenance?: unknown; question?: unknown; context?: unknown; mode?: unknown;
				answers?: Array<{ type?: unknown; value?: unknown }>;
			} } } | null;
			const result = reply?.data;
			const answer = result?.details;
			if (reply?.success !== true || result?.isError === true) {
				return finish("cancelled", new Error("The memory question failed. Nothing was approved."));
			}
			if (answer?.status === "cancelled" || answer?.status === "unavailable") return finish("cancelled");
			if (answer?.status !== "answered" || answer.provenance !== "interactive-user"
				|| answer.question !== question || answer.context !== details || answer.mode !== "single-select"
				|| !Array.isArray(answer.answers) || answer.answers.length !== 1) {
				return finish("cancelled", new Error("No matching human memory decision was received. Nothing was approved."));
			}
			const choice = answer.answers[0];
			const value = choice?.value;
			if (choice?.type !== "option" || (value !== "approve" && value !== "reject" && value !== "defer")) return finish("cancelled");
			finish(value);
		});
		signal.addEventListener("abort", abort, { once: true });
		if (signal.aborted) return abort();
		pi.events.emit(channel, {
			requestId: requestID,
			signal,
			params: {
				question,
				details,
				options: [{ label: "Approve", value: "approve" }, { label: "Reject", value: "reject" }, { label: "Defer", value: "defer" }],
				policy: { taskId: `memory-review:${preview.candidateID}`, scope: `Exact memory proposal ${preview.digest}`, kind: "approval" },
			},
		});
	});
}
