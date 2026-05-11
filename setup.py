"""
Build the macOS app bundle:
    python3 setup.py py2app

The built app will be in dist/Listen.app
"""

from setuptools import find_packages, setup

APP = ["main.py"]
DATA_FILES = ["assets/Listen.icns"]
OPTIONS = {
    "argv_emulation": True,
    "packages": [
        "openai",
        "requests",
        "numpy",
        "pynput",
        "rumps",
        "listen",
        "listen.providers",
    ],
    "includes": [
        "pynput.keyboard._darwin",
        "pynput.mouse._darwin",
        "ApplicationServices",
    ],
    "iconfile": "assets/Listen.icns",
    "plist": {
        "CFBundleName": "Listen",
        "CFBundleDisplayName": "Listen",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "0.1.0",
        "CFBundleIdentifier": "com.listen.app",
        "LSUIElement": True,
        "NSMicrophoneUsageDescription": "Listen records your voice for AI transcription.",
        "NSInputMonitoringUsageDescription": "Listen needs to detect the hotkey you hold to record.",
        "NSAccessibilityUsageDescription": "Listen pastes the transcribed text into the focused app.",
        "NSAppleEventsUsageDescription": "Listen pastes text via system events when needed.",
    },
}

setup(
    name="Listen",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
    python_requires=">=3.9",
)
