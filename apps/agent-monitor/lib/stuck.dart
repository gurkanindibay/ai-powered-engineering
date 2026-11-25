import 'models.dart';

enum Health { active, idle, stuck }

class Assessment {
  const Assessment(this.health, this.reason);

  final Health health;
  final String reason;
}

/// Decides whether a work item looks stuck. Pure, so it is unit tested.
///
/// stuck  - the PR's checks fail, or nothing happened for [stuckAfter]
/// idle   - nothing happened for half of [stuckAfter]
/// active - otherwise, or the collector saw the claiming session recently
Assessment assess(WorkItem item, UsageSnapshot snapshot, Duration stuckAfter, DateTime now) {
  final pull = item.pull;
  if (pull != null && pull.checks == CheckState.failure) {
    return const Assessment(Health.stuck, 'CI checks failing');
  }
  var last = item.lastActivity;
  final claim = item.claim;
  final session = claim == null ? null : snapshot.sessionFor(claim);
  final seen = session?.lastActivity;
  if (seen != null && seen.isAfter(last)) last = seen;
  final quiet = now.difference(last);
  if (quiet >= stuckAfter) {
    return Assessment(Health.stuck, 'No activity for ${describe(quiet)}');
  }
  if (quiet >= stuckAfter ~/ 2) {
    return Assessment(Health.idle, 'Quiet for ${describe(quiet)}');
  }
  return Assessment(
    Health.active,
    session != null ? 'Session active ${describe(quiet)} ago' : 'Updated ${describe(quiet)} ago',
  );
}

String describe(Duration d) {
  if (d.isNegative) return 'now';
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m';
}
