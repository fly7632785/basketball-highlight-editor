# Desktop App

Flutter desktop application for V1. The UI talks to the local Python Engine through the JSON Lines protocol described in `docs/architecture/ENGINE_PROTOCOL_V1.md`.

## Current stack

- Flutter / Dart
- Riverpod `ProjectNotifier` session layer
- go_router `StatefulShellRoute` with four desktop sections
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

The project was developed with Flutter 3.44.8. From the repository root, use a compatible Flutter SDK on `PATH` (the local `.tooling/` SDK is intentionally not committed):

```bash
cd <repo-root>/apps/desktop
flutter pub get
flutter analyze
flutter test
flutter build macos --debug
```

The repository currently uses the platform fallback font in source builds. A distributable build must provide a properly licensed font asset and retain its license notice.

The application modules follow:

- `docs/architecture/ARCHITECTURE_V1.md`
- `docs/architecture/ENGINE_PROTOCOL_V1.md`
- `design-system/courtside/MASTER.md`
- `design-system/courtside/pages/review.md`
