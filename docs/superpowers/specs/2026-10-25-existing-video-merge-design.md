# Existing Video Merge Design

## Goal

Let a user combine several previously exported local videos into one MP4 without
creating a project or running basketball analysis again.

## Entry and UI

Add a `合并已有视频` action to the desktop Export screen, alongside the
existing project-candidate export flow. It opens a dedicated dialog rather than
reusing Import, because these files are final media inputs rather than videos to
analyse.

The dialog provides:

- a multi-file picker for local video files;
- an ordered list showing each selected filename and duration;
- move up, move down, and remove controls;
- an output-file picker; and
- a `合并并导出` action with progress and an in-place error message.

Selection order is the initial merge order. The user can explicitly change it
before starting the job.

## Processing

The desktop app passes the ordered input paths and selected output path to a
new Engine command. The Engine validates that at least one readable input video
exists and that the output path is distinct from every input.

The exporter first attempts FFmpeg concat demuxer stream-copy merging for
compatible inputs. If stream copy fails because inputs do not share compatible
media parameters, it retries with the existing Windows encoder fallback policy
to produce one playable MP4. The source videos are never changed or deleted.

## Failure Handling

The dialog keeps its selected list and order when an operation fails. It
provides actionable messages for empty selection, inaccessible/missing inputs,
invalid output location, cancellation, and FFmpeg failure. Existing candidate
export and export history remain unchanged.

## Testing

- Engine tests cover ordered input validation, a compatible concat invocation,
  and re-encoding fallback after stream-copy failure.
- Flutter widget tests cover opening the dialog, list reordering/removal,
  disabled merge action without inputs or output, and dispatch of the ordered
  merge request.
- Existing Export screen tests continue to prove project-candidate export
  behavior is unaffected.

## Success Criteria

A user can select multiple previously exported videos, adjust their order,
choose a destination, and receive one playable MP4 with the same segment order.
No project analysis is created or rerun.
