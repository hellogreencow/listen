#!/usr/bin/env python3
"""Entry point for py2app bundle."""

import sys
sys.path.insert(0, "src")

from listen.app_native import main

if __name__ == "__main__":
    main()
