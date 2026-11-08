"""Routing regression evaluation and paired pilot telemetry (decimal costs)."""
from decimal import Decimal
from statistics import median

from .routing import HarnessError, TIERS, assess, money


def evaluate(cases: list[dict], measurements: list[dict] | None = None) -> dict:
    if not isinstance(cases, list) or not cases:
        raise HarnessError("Evaluation cases must be a nonempty list")
    results = []
    ids = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or case["id"] in ids or case.get("expected") not in TIERS:
            raise HarnessError("Evaluation cases require unique ids and expected tiers")
        ids.add(case["id"])
        actual = assess(case["task"], **case.get("risk", {})).tier
        results.append({"id": case["id"], "expected": case["expected"], "actual": actual,
                        "under_classified": TIERS.index(actual) < TIERS.index(case["expected"]),
                        "matched": actual == case["expected"]})
    output = {"cases": results, "sample_size": len(results), "matched": sum(r["matched"] for r in results),
              "under_classified": sum(r["under_classified"] for r in results),
              "note": "Synthetic routing regressions are not model quality or rare-event safety evidence."}
    if measurements is not None:
        if not isinstance(measurements, list) or not measurements:
            raise HarnessError("Measurements must be a nonempty paired list")
        groups = {"baseline": [], "routed": []}
        pairs = set()
        for value in measurements:
            if not isinstance(value, dict) or value.get("arm") not in groups or value.get("task_id") not in ids:
                raise HarnessError("Measurements reference unknown arms/tasks")
            repetition = value.get("repetition", 0)
            if type(repetition) is not int or repetition < 0:
                raise HarnessError("Invalid repetition")
            key = (value["task_id"], repetition, value["arm"])
            if key in pairs:
                raise HarnessError("Duplicate paired measurement")
            pairs.add(key)
            if type(value.get("accepted")) is not bool or type(value.get("duration_ms")) is not int or value["duration_ms"] < 0:
                raise HarnessError("Measurements require accepted and nonnegative duration_ms")
            money(value.get("cost"))
            groups[value["arm"]].append(value)
        if {(t, n) for t, n, a in pairs if a == "baseline"} != {(t, n) for t, n, a in pairs if a == "routed"}:
            raise HarnessError("Every measurement needs a matching baseline/routed pair")
        output["measurements"] = {}
        for arm, values in groups.items():
            total = sum((money(v["cost"]) for v in values), Decimal(0))
            accepted = sum(v["accepted"] for v in values)
            durations = sorted(v["duration_ms"] for v in values)
            output["measurements"][arm] = {"sample_size": len(values), "accepted": accepted,
                                          "total_cost": str(total), "cost_per_accepted": str(total / accepted) if accepted else None,
                                          "median_ms": median(durations), "p95_ms": durations[max(0, (95 * len(durations) + 99) // 100 - 1)]}
    return output
