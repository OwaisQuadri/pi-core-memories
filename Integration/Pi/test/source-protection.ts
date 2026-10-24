import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default sourceProtectionFixture;

export function sourceProtectionFixture(pi?: ExtensionAPI): ExtensionAPI {
	function provide(value: unknown) {
		const request = value as { provide(service: unknown): void };
		request.provide({ version: 1, async redact(input: { requestID: string; pieces: readonly string[] }) {
			return { status: "checked", requestID: input.requestID, policy: "pi-credentials/redact-v1", pieces: [...input.pieces] };
		} });
	}
	if (pi?.events) {
		pi.events.on("pi-credentials:redaction-service:v1", provide);
		return pi;
	}
	return { ...pi, events: { emit(channel: string, value: unknown) {
		if (channel === "pi-credentials:redaction-service:v1") provide(value);
	} } } as ExtensionAPI;
}
