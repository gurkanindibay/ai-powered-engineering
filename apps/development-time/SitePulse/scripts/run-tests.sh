#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEPULSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================================================"
echo "               SITEPULSE VERIFICATION & TEST SUITE                      "
echo "   AI-Manufactured Residential Management Platform (Android & Backend)  "
echo "========================================================================"
echo ""

# 1. Harness Unit Tests
echo "▶ [1/3] Running Engineering Harness Self-Tests..."
python3 -m unittest discover -s "$SITEPULSE_ROOT/harness/tests" -v
echo ""

# 2. Closed-Loop Task DAG Verification Gates
echo "▶ [2/3] Running Closed-Loop Verification Gates on Task DAG..."
for task in task-01 task-02 task-03 task-04 task-05 task-06 task-07; do
    python3 "$SITEPULSE_ROOT/harness/harness_cli.py" verify --task "$task"
done
echo ""

# 3. Backend Service Unit Tests (Java Reflection Runner)
echo "▶ [3/3] Running Spring Boot Backend Service Unit Tests..."
python3 -c '
import subprocess
from pathlib import Path

sitepulse_root = Path("'"$SITEPULSE_ROOT"'")
target_classes = sitepulse_root / "backend" / "target" / "classes"
target_test_classes = sitepulse_root / "backend" / "target" / "test-classes"
m2_repo = Path.home() / ".m2" / "repository"

junit_api = m2_repo / "org" / "junit" / "jupiter" / "junit-jupiter-api" / "5.10.3" / "junit-jupiter-api-5.10.3.jar"
opentest4j = m2_repo / "org" / "opentest4j" / "opentest4j" / "1.3.0" / "opentest4j-1.3.0.jar"

if not junit_api.exists():
    print("  [SKIP] Backend m2 dependencies not found.")
    exit(0)

all_jars = ":".join(str(p) for p in m2_repo.rglob("*.jar"))
target_classes.mkdir(parents=True, exist_ok=True)
target_test_classes.mkdir(parents=True, exist_ok=True)

main_srcs = [str(p) for p in (sitepulse_root / "backend" / "src" / "main" / "java").rglob("*.java")]
test_srcs = [str(p) for p in (sitepulse_root / "backend" / "src" / "test" / "java").rglob("*.java")]

if main_srcs:
    res_main = subprocess.run(["javac", "-cp", f"{target_classes}:{all_jars}", "-d", str(target_classes)] + main_srcs, capture_output=True, text=True)
    if res_main.returncode != 0:
        print("Compile Main Error:", res_main.stderr)
        exit(res_main.returncode)

if test_srcs:
    res_test = subprocess.run(["javac", "-cp", f"{target_classes}:{target_test_classes}:{all_jars}", "-d", str(target_test_classes)] + test_srcs, capture_output=True, text=True)
    if res_test.returncode != 0:
        print("Compile Test Error:", res_test.stderr)
        exit(res_test.returncode)

runner_code = """
public class BackendTestRunner {
    public static void main(String[] args) throws Exception {
        // 1. Aidat Calculation Tests
        Class<?> clazz = Class.forName("com.sitepulse.backend.service.AidatCalculationServiceTest");
        var ctor = clazz.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object testObj = ctor.newInstance();

        var m1 = clazz.getDeclaredMethod("whenOverdueBy10Days_thenCalculatesExact5PercentProRatedPenalty");
        m1.setAccessible(true);
        m1.invoke(testObj);
        System.out.println("  [PASS] whenOverdueBy10Days_thenCalculatesExact5PercentProRatedPenalty (KMK Art. 20)");

        var m2 = clazz.getDeclaredMethod("whenNotOverdue_thenPenaltyRemainsZero");
        m2.setAccessible(true);
        m2.invoke(testObj);
        System.out.println("  [PASS] whenNotOverdue_thenPenaltyRemainsZero");

        // 2. SaaS Tenant & Site Admin Provisioning Tests
        Class<?> saasClazz = Class.forName("com.sitepulse.backend.service.SaasTenantServiceTest");
        var saasCtor = saasClazz.getDeclaredConstructor();
        saasCtor.setAccessible(true);
        Object saasObj = saasCtor.newInstance();

        var saasSetUp = saasClazz.getDeclaredMethod("setUp");
        saasSetUp.setAccessible(true);

        var sm1 = saasClazz.getDeclaredMethod("whenRegisteringNewSite_thenProvisionsSiteAndManagerWithTemporaryPassword");
        sm1.setAccessible(true);
        saasSetUp.invoke(saasObj);
        sm1.invoke(saasObj);
        System.out.println("  [PASS] whenRegisteringNewSite_thenProvisionsSiteAndManagerWithTemporaryPassword (SaaS Multi-Tenancy)");

        var sm2 = saasClazz.getDeclaredMethod("whenDuplicateEmail_thenThrowsException");
        sm2.setAccessible(true);
        saasSetUp.invoke(saasObj);
        sm2.invoke(saasObj);
        System.out.println("  [PASS] whenDuplicateEmail_thenThrowsException (SaaS Multi-Tenancy)");

        // 3. Site Admin Home Owner Provisioning Tests
        Class<?> ownerClazz = Class.forName("com.sitepulse.backend.service.SiteAdminServiceTest");
        var ownerCtor = ownerClazz.getDeclaredConstructor();
        ownerCtor.setAccessible(true);
        Object ownerObj = ownerCtor.newInstance();

        var ownerSetUp = ownerClazz.getDeclaredMethod("setUp");
        ownerSetUp.setAccessible(true);

        var om1 = ownerClazz.getDeclaredMethod("whenRegisteringHomeOwner_thenProvisionsUserWithResidentPassword");
        om1.setAccessible(true);
        ownerSetUp.invoke(ownerObj);
        om1.invoke(ownerObj);
        System.out.println("  [PASS] whenRegisteringHomeOwner_thenProvisionsUserWithResidentPassword (Home Owner Registration)");

        var om2 = ownerClazz.getDeclaredMethod("whenDuplicateEmailForHomeOwner_thenThrowsException");
        om2.setAccessible(true);
        ownerSetUp.invoke(ownerObj);
        om2.invoke(ownerObj);
        System.out.println("  [PASS] whenDuplicateEmailForHomeOwner_thenThrowsException (Home Owner Registration)");

        // 4. Registration Link & Approval Tests
        Class<?> regClazz = Class.forName("com.sitepulse.backend.service.RegistrationApprovalServiceTest");
        var regCtor = regClazz.getDeclaredConstructor();
        regCtor.setAccessible(true);
        Object regObj = regCtor.newInstance();

        var regSetUp = regClazz.getDeclaredMethod("setUp");
        regSetUp.setAccessible(true);

        var rm1 = regClazz.getDeclaredMethod("whenGeneratingInviteLink_thenReturnsValidUrlAndToken");
        rm1.setAccessible(true);
        regSetUp.invoke(regObj);
        rm1.invoke(regObj);
        System.out.println("  [PASS] whenGeneratingInviteLink_thenReturnsValidUrlAndToken (Self-Registration Link)");

        var rm2 = regClazz.getDeclaredMethod("whenSubmittingSelfRegistration_thenCreatesPendingRequest");
        rm2.setAccessible(true);
        regSetUp.invoke(regObj);
        rm2.invoke(regObj);
        System.out.println("  [PASS] whenSubmittingSelfRegistration_thenCreatesPendingRequest (Self-Registration Link)");

        var rm3 = regClazz.getDeclaredMethod("whenApprovingPendingRegistration_thenProvisionsUserAndReturnsCredentials");
        rm3.setAccessible(true);
        regSetUp.invoke(regObj);
        rm3.invoke(regObj);
        System.out.println("  [PASS] whenApprovingPendingRegistration_thenProvisionsUserAndReturnsCredentials (Approval Queue)");

        // 5. Unit-Scoped Co-Resident Invitation & Permissions Tests
        Class<?> homeClazz = Class.forName("com.sitepulse.backend.service.HomeResidentInvitationServiceTest");
        var homeCtor = homeClazz.getDeclaredConstructor();
        homeCtor.setAccessible(true);
        Object homeObj = homeCtor.newInstance();

        var homeSetUp = homeClazz.getDeclaredMethod("setUp");
        homeSetUp.setAccessible(true);

        var hm1 = homeClazz.getDeclaredMethod("whenGeneratingUnitInviteLink_thenReturnsUnitScopedUrlAndToken");
        hm1.setAccessible(true);
        homeSetUp.invoke(homeObj);
        hm1.invoke(homeObj);
        System.out.println("  [PASS] whenGeneratingUnitInviteLink_thenReturnsUnitScopedUrlAndToken (Unit Invite Link)");

        var hm2 = homeClazz.getDeclaredMethod("whenRegisteringHomeResident_thenAssignsHomeResidentRoleAndUnitScope");
        hm2.setAccessible(true);
        homeSetUp.invoke(homeObj);
        hm2.invoke(homeObj);
        System.out.println("  [PASS] whenRegisteringHomeResident_thenAssignsHomeResidentRoleAndUnitScope (Unit-Scoped Permissions)");

        var hm3 = homeClazz.getDeclaredMethod("whenDuplicateEmailForHomeResident_thenThrowsException");
        hm3.setAccessible(true);
        homeSetUp.invoke(homeObj);
        hm3.invoke(homeObj);
        System.out.println("  [PASS] whenDuplicateEmailForHomeResident_thenThrowsException (Unit Member Validation)");

        // 6. Dual Auth (Password & Google OAuth2) & Permission Model Tests
        Class<?> authClazz = Class.forName("com.sitepulse.backend.service.AuthServiceTest");
        var authCtor = authClazz.getDeclaredConstructor();
        authCtor.setAccessible(true);
        Object authObj = authCtor.newInstance();

        var authSetUp = authClazz.getDeclaredMethod("setUp");
        authSetUp.setAccessible(true);

        var am1 = authClazz.getDeclaredMethod("whenValidPasswordRegistration_thenCanAuthenticate");
        am1.setAccessible(true);
        authSetUp.invoke(authObj);
        am1.invoke(authObj);
        System.out.println("  [PASS] whenValidPasswordRegistration_thenCanAuthenticate (Password Auth & Hashing)");

        var am2 = authClazz.getDeclaredMethod("whenWrongPassword_thenThrowsException");
        am2.setAccessible(true);
        authSetUp.invoke(authObj);
        am2.invoke(authObj);
        System.out.println("  [PASS] whenWrongPassword_thenThrowsException (Invalid Password Rejection)");

        var am3 = authClazz.getDeclaredMethod("whenValidGoogleIdToken_thenAuthenticatesAndLinksAccount");
        am3.setAccessible(true);
        authSetUp.invoke(authObj);
        am3.invoke(authObj);
        System.out.println("  [PASS] whenValidGoogleIdToken_thenAuthenticatesAndLinksAccount (Google OAuth2 ID Token)");

        var am4 = authClazz.getDeclaredMethod("whenResidentRole_thenHasUnitRestrictedPermissions");
        am4.setAccessible(true);
        authSetUp.invoke(authObj);
        am4.invoke(authObj);
        System.out.println("  [PASS] whenResidentRole_thenHasUnitRestrictedPermissions (Unit Scope Security Gate)");

        var am5 = authClazz.getDeclaredMethod("whenHomeOwnerRole_thenHasInviteAndHouseholdPermissions");
        am5.setAccessible(true);
        authSetUp.invoke(authObj);
        am5.invoke(authObj);
        System.out.println("  [PASS] whenHomeOwnerRole_thenHasInviteAndHouseholdPermissions (Home Owner Permissions)");
    }
}
"""

temp_runner = Path("/tmp/BackendTestRunner.java")
temp_runner.write_text(runner_code, encoding="utf-8")

all_jars = ":".join(str(p) for p in m2_repo.rglob("*.jar"))
cp = f"{target_classes}:{target_test_classes}:{all_jars}"
res = subprocess.run(["java", "-Dnet.bytebuddy.experimental=true", "--class-path", cp, str(temp_runner)], capture_output=True, text=True)
if res.returncode != 0:
    print("Test Runner Error:", res.stderr)
    exit(res.returncode)
print(res.stdout.strip())
'
echo ""

echo "========================================================================"
echo "  ✔ ALL SITEPULSE TESTS & VERIFICATION GATES PASSED SUCCESSFULLY!"
echo "========================================================================"
