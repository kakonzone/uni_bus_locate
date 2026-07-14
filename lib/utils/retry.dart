import 'dart:async';

import 'package:flutter/foundation.dart';

/// Runs [action] up to [maxAttempts] times with [delayBetween] between failures.
/// Intended for one-shot Firebase fetches — not for stream listeners.
Future<T> withRetry<T>(
  Future<T> Function() action, {
  int maxAttempts = 3,
  Duration delayBetween = const Duration(seconds: 2),
  String? logTag,
}) async {
  Object? lastError;
  StackTrace? lastStack;

  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await action();
    } catch (e, st) {
      lastError = e;
      lastStack = st;
      if (logTag != null) {
        debugPrint(
          'UniTrack [$logTag]: attempt $attempt/$maxAttempts failed → $e',
        );
      }
      if (attempt < maxAttempts) {
        await Future<void>.delayed(delayBetween);
      }
    }
  }

  Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
}

/// Retry configuration constants for stream listeners.
class StreamRetryConfig {
  const StreamRetryConfig({
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 2),
  });

  final int maxRetries;
  final Duration retryDelay;
}

/// Default retry configuration for Firebase stream listeners.
const defaultStreamRetryConfig = StreamRetryConfig();
