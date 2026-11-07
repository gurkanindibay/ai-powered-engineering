"""Page objects for the SitePulse Flutter web client.

Rules: tests never use raw selectors; ids come from `testId(...)` in the app.
The bottom navigation items are not widgets that can carry an id, so they are
located by their (Turkish) label in one place: `Shell.NAV`.
"""
from .login import LoginPage
from .shell import Shell
from .resident import ResidentHome
from .manager import ManagerCockpit, ResidentsTab, DuesManagement, AddResidentForm
from .saas import SaasAdmin

__all__ = ["LoginPage", "Shell", "ResidentHome", "ManagerCockpit", "ResidentsTab", "DuesManagement",
           "AddResidentForm", "SaasAdmin"]
