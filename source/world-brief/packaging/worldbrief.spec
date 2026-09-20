# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec shared by the macOS, Windows and Linux builds.

    pyinstaller packaging/worldbrief.spec --noconfirm

Everything the running app needs is inside the bundle: the FastAPI backend, the frontend with
its vendored Leaflet, the interface translations, scikit-learn and the CTranslate2 runtime.
Only the news itself, and any language packages the user installs, come down from the network.
"""
import sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

ROOT = Path(SPECPATH).resolve().parent
NAME = "World Brief" if sys.platform == "darwin" else "worldbrief"
VERSION = "1.0.0"

# --------------------------------------------------------------------------------- resources

datas = [
    (str(ROOT / "frontend"), "frontend"),
    (str(ROOT / "packaging" / "icons" / "icon-256.png"), "packaging/icons"),
    (str(ROOT / "packaging" / "icons" / "icon-512.png"), "packaging/icons"),
]

# Packages that load files from their own directory at runtime.
for pkg in ("certifi", "ctranslate2", "sentencepiece", "sklearn", "scipy"):
    try:
        datas += collect_data_files(pkg)
    except Exception:  # noqa: BLE001 - an absent optional package is not an error
        pass

# --------------------------------------------------------------------------------- imports

hiddenimports = [
    # uvicorn resolves its protocol and loop implementations by name at runtime.
    "uvicorn.logging", "uvicorn.loops", "uvicorn.loops.auto", "uvicorn.loops.asyncio",
    "uvicorn.protocols", "uvicorn.protocols.http", "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl", "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto", "uvicorn.lifespan", "uvicorn.lifespan.on",
    "anyio._backends._asyncio",
    # the application itself
    "backend", "backend.app", "backend.pipeline", "backend.translate", "backend.ml",
    "desktop", "desktop.main",
    # scientific stack pieces PyInstaller cannot see through
    "sklearn.utils._typedefs", "sklearn.utils._heap", "sklearn.utils._sorting",
    "sklearn.utils._vector_sentinel", "sklearn.neighbors._partition_nodes",
    "scipy._lib.messagestream",
    "sentencepiece", "ctranslate2",
]
hiddenimports += collect_submodules("feedparser")

# pywebview chooses its backend at runtime, so each one has to be named here. Only the three
# that belong to this platform are included: the Android backend needs a toolkit that exists
# only on a phone, and the Windows and GTK ones pull in stacks the other systems do not have.
if sys.platform == "darwin":
    hiddenimports += ["webview.platforms.cocoa"]
elif sys.platform == "win32":
    hiddenimports += ["webview.platforms.edgechromium", "webview.platforms.winforms",
                      "webview.platforms.mshtml", "webview.platforms.win32"]
else:
    hiddenimports += ["webview.platforms.gtk", "webview.platforms.qt"]

excludes = [
    "tkinter", "matplotlib", "pytest", "IPython", "notebook", "setuptools", "pip",
    "PySide6", "PyQt5", "PyQt6", "wx", "test", "pydoc_data",
]

a = Analysis(
    [str(ROOT / "desktop" / "main.py")],
    pathex=[str(ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[str(ROOT / "packaging" / "runtime_hook.py")],
    excludes=excludes,
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name=NAME,
    debug=False,
    strip=False,
    upx=False,
    console=False,
    icon=str(ROOT / "packaging" / "icons" / ("icon.icns" if sys.platform == "darwin" else "icon.ico")),
)

coll = COLLECT(
    exe, a.binaries, a.datas,
    strip=False, upx=False, name="worldbrief",
)

if sys.platform == "darwin":
    app = BUNDLE(
        coll,
        name=f"{NAME}.app",
        icon=str(ROOT / "packaging" / "icons" / "icon.icns"),
        bundle_identifier="com.worldbrief.app",
        version=VERSION,
        info_plist={
            "CFBundleName": "World Brief",
            "CFBundleDisplayName": "World Brief",
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": VERSION,
            "NSHighResolutionCapable": True,
            "LSMinimumSystemVersion": "11.0",
            "LSApplicationCategoryType": "public.app-category.news",
            "NSHumanReadableCopyright": "World Brief — runs entirely on your machine.",
            # The window is a WKWebView on 127.0.0.1; plain HTTP to loopback must be allowed.
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        },
    )
