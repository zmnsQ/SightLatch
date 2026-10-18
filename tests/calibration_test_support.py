"""Compile production calibration types; replace only Apple platform/storage seams."""
from pathlib import Path
import sys


def write_production_sources(root: Path, build: Path) -> list[Path]:
    models = (root / "ios/Shared/Models.swift").read_text()
    models = models.replace("import ActivityKit\n", "")
    start = models.index("struct PilotActivityAttributes:")
    end = models.index("enum PilotError:", start)
    models = models[:start] + models[end:]

    network = (root / "ios/Shared/Network.swift").read_text()
    start = network.index("struct DeviceStatus:")
    end = network.index("enum DevicePairingCloseResult", start)
    device = "import Foundation\n" + network[start:end]

    store = (root / "ios/Shared/SharedStore.swift").read_text().split("enum SecretStore", 1)[0]
    store = store.replace("import Security\n", "").replace(
        "import Darwin", "#if canImport(Darwin)\nimport Darwin\n#else\nimport Glibc\n#endif"
    )
    start = store.index("    private var directory: URL? {")
    end = store.index("    var available:", start)
    store = store[:start] + (
        '    private var directory: URL? { URL(fileURLWithPath: '
        'ProcessInfo.processInfo.environment["SIGHTLATCH_TEST_STORE"]!) }\n'
    ) + store[end:]
    store = store.replace("[.atomic, .completeFileProtection]", "[.atomic]")
    store = store.replace("[.atomic, .completeFileProtectionUntilFirstUserAuthentication]", "[.atomic]")

    paths = []
    for name, source in [("Models.swift", models), ("DeviceStatus.swift", device), ("SharedStore.swift", store)]:
        path = build / name
        path.write_text(source)
        paths.append(path)
    (build / "store").mkdir()
    return paths


if __name__ == "__main__":
    write_production_sources(Path(__file__).resolve().parents[1], Path(sys.argv[1]))
