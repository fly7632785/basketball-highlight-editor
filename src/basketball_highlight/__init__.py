"""Shared bootstrap for analysis scripts, before inference imports torch."""

import os

# PyTorch reads this when its MPS backend is imported, not at the failing op.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
