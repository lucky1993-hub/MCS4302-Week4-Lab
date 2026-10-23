import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'api/api_client.dart';
import 'notifications.dart';

/// Task name passed to WorkManager. Every job in this lab runs the same task.
const syncTaskName = 'mcs4302.sync';

/// Entry point that Android starts when a job is due.
///
/// It may run in a NEW isolate (or a new process, if Android killed the app),
/// so it must not rely on anything the UI created: it builds its own ApiClient
/// and initialises notifications itself. The pragma stops the compiler from
/// removing it, because nothing in the app calls it directly.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    final jobId = inputData?['job_id'] as String? ?? 'unknown';
    final label = inputData?['label'] as String? ?? '?';

    debugPrint('[JOB] $jobId started on the device at ${DateTime.now()}');

    final api = ApiClient();

    try {
      // TODO 4a: Record the worker's start time before fetching items.
      // Keep this in its own try/catch so logging failure does not stop the job.
      try {
        await api.logJob(
          jobId: jobId,
          label: label,
          event: 'started',
        );
      } catch (e) {
        debugPrint('[JOB] $jobId started-event logging failed: $e');
      }

      // Fetch items from the backend.
      final items = await api.getItems();

      // Record successful completion using the server clock.
      await api.logJob(
        jobId: jobId,
        label: label,
        event: 'ran',
        detail: 'items=${items.length}',
      );

      // A failed notification must not fail the job.
      try {
        await Notifications.show(
          id: jobId.hashCode & 0x7fffffff,
          title: 'Items synced ($label)',
          body: '${items.length} items on the server',
        );
      } catch (e) {
        debugPrint('[JOB] $jobId notification failed: $e');
      }

      debugPrint('[JOB] $jobId finished');

      // Success: the sync completed, so WorkManager need not retry.
      return true;
    } catch (e) {
      debugPrint('[JOB] $jobId failed: $e');

      // Failure: ask WorkManager to retry the job later.
      return false;
    } finally {
      api.close();
    }
  });
}

class BackgroundJobs {
  BackgroundJobs._();

  /// Call once in main(), before runApp().
  static Future<void> init() =>
      Workmanager().initialize(callbackDispatcher);

  /// Asks Android to run one sync job no earlier than [delay] from now,
  /// when a network is available.
  ///
  /// [delay] is a MINIMUM, not a deadline: WorkManager runs deferrable work,
  /// and Doze and App Standby can postpone it further.
  static Future<String> scheduleSync(
      ApiClient api,
      String label, {
        Duration delay = const Duration(seconds: 60),
      }) async {
    final jobId = '$label-${DateTime.now().millisecondsSinceEpoch}';

    // Register with Android first. If this throws, nothing is logged,
    // so the backend never shows a job that does not exist.
    await Workmanager().registerOneOffTask(
      jobId,
      syncTaskName,
      initialDelay: delay,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
      inputData: {
        'job_id': jobId,
        'label': label,
      },
    );

    // Record scheduling time on the server.
    // If logging fails, cancel the job so the two stay consistent.
    try {
      await api.logJob(
        jobId: jobId,
        label: label,
        event: 'scheduled',
        requestedDelaySeconds: delay.inSeconds.toDouble(),
      );
    } catch (e) {
      await Workmanager().cancelByUniqueName(jobId);
      rethrow;
    }

    debugPrint(
      '[JOB] $jobId scheduled, minimum delay ${delay.inSeconds} s',
    );

    return jobId;
  }

  static Future<void> cancelAll() => Workmanager().cancelAll();
}