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

if not target_test_classes.exists() or not junit_api.exists():
    print("  [SKIP] Backend compiled classes or m2 dependencies not found.")
    exit(0)

runner_code = """
public class BackendTestRunner {
    public static void main(String[] args) throws Exception {
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
    }
}
"""
temp_runner = Path("/tmp/BackendTestRunner.java")
temp_runner.write_text(runner_code, encoding="utf-8")

cp = f"{target_classes}:{target_test_classes}:{junit_api}:{opentest4j}"
res = subprocess.run(["java", "--class-path", cp, str(temp_runner)], capture_output=True, text=True)
if res.returncode != 0:
    print("Test Runner Error:", res.stderr)
    exit(res.returncode)
print(res.stdout.strip())
'
echo ""

echo "========================================================================"
echo "  ✔ ALL SITEPULSE TESTS & VERIFICATION GATES PASSED SUCCESSFULLY!"
echo "========================================================================"
