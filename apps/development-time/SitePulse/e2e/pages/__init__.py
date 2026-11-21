"""Page objects for the SitePulse Flutter web client.

Rules: tests never use raw selectors; ids come from `testId(...)` in the app.
The bottom navigation items are not widgets that can carry an id, so they are
located by their (Turkish) label in one place: `Shell.NAV`.
"""
from .login import LoginPage
from .shell import ProfileSheet, Shell
from .resident import ResidentHome
from .manager import (AddBlockForm, AddResidentForm, CapitalProjects, DuesManagement, ImportSummary, ManagerCockpit,
                      Occupancy, PaymentStream, ResidentsTab)
from .person import PersonPicker, UnitWorkspace
from .saas import AddSiteForm, SaasAdmin, SiteCredentials

__all__ = ["LoginPage", "Shell", "ProfileSheet", "ResidentHome", "ManagerCockpit", "ResidentsTab", "DuesManagement",
           "AddResidentForm", "AddBlockForm", "ImportSummary", "PaymentStream", "CapitalProjects", "Occupancy",
           "SaasAdmin", "AddSiteForm", "SiteCredentials", "PersonPicker", "UnitWorkspace"]
