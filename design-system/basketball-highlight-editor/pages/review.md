# Review Workspace Page Override

## Purpose

用于长视频候选审核，不使用营销型 Hero 布局。视频画面和审核操作优先级最高。

## Layout

- Desktop wide: 240px navigation, flexible video workspace, 360px candidate panel.
- Desktop narrow: collapsible navigation and candidate panel.
- Mobile later: video-first stack with swipeable candidate cards.
- Bottom timeline and batch action bar remain visually stable.

## States

| State | Color | Additional cue |
|---|---|---|
| Pending | `#F97316` | “待审核” label |
| Goal | `#22C55E` | check icon + label |
| Excluded | `#64748B` | slash icon + label |
| Error | `#EF4444` | error icon + message |

Never communicate state with color alone.

## Interaction

- Space: play/pause.
- Left / right: move through the clip.
- Enter: confirm goal.
- Backspace: exclude.
- Cmd/Ctrl+Z: undo.
- Candidate actions use minimum 44px hit targets.
- Use visible keyboard focus rings.
- Avoid layout-shifting hover effects.
