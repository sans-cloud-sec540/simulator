import os
import re
import subprocess


def _version() -> str:
    sha = os.environ.get("GITHUB_SHA")
    if sha:
        return sha[:12]
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return "dev"


VERSION = _version()
_TF_LINK = re.compile(r"(\]\([^)]*?\.tf)(\))")


def on_page_markdown(markdown, **kwargs):
    return _TF_LINK.sub(rf"\1?v={VERSION}\2", markdown)
