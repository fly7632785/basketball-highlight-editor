# Desktop App

Flutter desktop application for V1. The UI talks to the local Python Engine through the JSON Lines protocol described in `docs/architecture/ENGINE_PROTOCOL_V1.md`.

## Current stack

- Flutter / Dart
- Lightweight `StatefulWidget` session layer for V1
- Riverpod / go_router remain optional follow-up refactors
- Material 3 with project Design Tokens
- JSON Lines connection to `engine/python`

## Application modules

- `lib/app.dart`: application shell and theme selection
- `lib/core/`: protocol client and app state
- `lib/features/home/`: project entry and recent projects
- `lib/features/import_video/`: video metadata and ROI setup
- `lib/features/review/`: candidate review workspace
- `lib/features/export/`: export actions and statistics

## Local development

The project was generated with Flutter 3.44.8. From the repository root, use the checked-in development SDK path or place Flutter on `PATH`:

```bash
cd /Users/macmima1234/basketball-highlight-editor/apps/desktop
../../.tooling/flutter/bin/flutter analyze
../../.tooling/flutter/bin/flutter test
../../.tooling/flutter/bin/flutter build macos --debug
```

The application modules follow:

- `docs/architecture/ARCHITECTURE_V1.md`
- `docs/architecture/ENGINE_PROTOCOL_V1.md`
- `design-system/basketball-highlight-editor/MASTER.md`
- `design-system/basketball-highlight-editor/pages/review.md`
