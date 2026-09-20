"""Finding data model shared by all scanner modules."""
from dataclasses import dataclass, field

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "review": 3, "info": 4}


@dataclass
class Finding:
    severity: str                       # critical | high | medium | review | info
    category: str                       # persistence | processes | files | privacy | browser | system | scanner
    title: str
    detail: str = ""
    paths: list = field(default_factory=list)   # implicated files/dirs; used for quarantine
    launchd_label: str = ""
    launchd_domain: str = ""            # "user" | "system"
    removable: bool = False             # eligible for automatic quarantine
    remediation: str = ""               # manual fix when removal is not file-based

    def to_dict(self):
        return dict(self.__dict__)
