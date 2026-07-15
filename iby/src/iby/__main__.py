"""Allow `python -m iby` in addition to the installed `iby` console script."""

from iby.cli import app

if __name__ == "__main__":
    app()
