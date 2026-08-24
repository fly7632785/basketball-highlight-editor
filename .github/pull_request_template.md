## Summary

<!-- What changed and why? Keep the scope focused. -->

## Verification

- [ ] `python scripts/check_docs_links.py`
- [ ] `.venv/bin/python -m pytest -q`
- [ ] `flutter analyze` and `flutter test` for affected Flutter app(s)
- [ ] `git diff --check`

## Release and data safety

- [ ] No real video, personal data, private path, secret, or unlicensed asset was added.
- [ ] Model, data, font, codec, and dependency license impact was checked when applicable.
- [ ] README or user-facing documentation was updated when behavior changed.
