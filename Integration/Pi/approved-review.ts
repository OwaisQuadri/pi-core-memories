import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Key, matchesKey, ScrollView, SelectList, Text } from "@earendil-works/pi-tui";
import { escapeDreamDisplay } from "./dream.ts";

export function chooseApprovedReview(ctx: ExtensionContext, details: string, isMutable: boolean, signal: AbortSignal): Promise<string> {
	return ctx.ui.custom<string>((tui, theme, _keys, done) => {
		const scroll = new ScrollView(new Text(details.split("\n").map(escapeDreamDisplay).join("\n"), 0, 0), { scrollbar: "always" });
		const choices = isMutable ? ["Back", "Defer", "Confirm reviewed"] : ["Back", "Defer"];
		const menu = new SelectList(choices.map((value) => ({ value, label: value })), 3, {
			selectedPrefix: (value) => theme.fg("accent", value), selectedText: (value) => theme.fg("accent", value),
			description: (value) => theme.fg("muted", value), scrollInfo: (value) => theme.fg("muted", value), noMatch: (value) => theme.fg("muted", value),
		});
		let isInputAction = false;
		function finish(value: string): void { signal.removeEventListener("abort", cancel); done(value); }
		function cancel(): void { finish("Back"); }
		signal.addEventListener("abort", cancel, { once: true });
		menu.onSelect = (item) => { if (isInputAction) finish(item.value); };
		if (signal.aborted) cancel();
		return {
			handleInput(data: string) {
				if (matchesKey(data, Key.escape)) { cancel(); return; }
				if (matchesKey(data, Key.pageUp) || matchesKey(data, "ctrl+b")) scroll.scrollBy(-10);
				else if (matchesKey(data, Key.pageDown) || matchesKey(data, "ctrl+f")) scroll.scrollBy(10);
				else {
					isInputAction = true;
					try { menu.handleInput(data); } finally { isInputAction = false; }
				}
				tui.requestRender();
			},
			render(width: number) {
				const actions = menu.render(width);
				const height = Math.max(3, Math.min(18, tui.terminal.rows - actions.length - 4));
				scroll.updateLayout(scroll.render(width).length, height, () => tui.requestRender());
				return [...scroll.render(width).slice(scroll.scrollTop, scroll.scrollTop + height), ...actions,
					...new Text("Ctrl+B/Ctrl+F: entry · Escape: Back", 0, 0).render(width)];
			},
			invalidate() { menu.invalidate(); scroll.invalidate(); },
		};
	});
}
