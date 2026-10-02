import 'dart:convert';
import 'dart:io';

import 'package:package_config/package_config.dart';

import 'worker_resolvers.dart';

/// Creates the resolver used by the current build_runner execution layer.
///
/// `build_resolvers` was folded into build_runner in the current stable
/// release. Supplying the worker's package config keeps the resolver's
/// analyzer view aligned with the remote asset filesystem.
WorkerResolversImpl createResolver(
  PackageConfig packageConfig,
  ResolverInitializationProfile profile,
) {
  final constructorTimer = profile.enabled ? (Stopwatch()..start()) : null;
  final resolver = WorkerResolversImpl.custom(
    packageConfig: packageConfig,
    profile: profile,
  );
  if (constructorTimer != null) {
    profile.resolverConstructorUs = constructorTimer.elapsedMicroseconds;
  }
  return resolver;
}

/// Stage timings for the lazy Analyzer resolver initialization path.
///
/// The resolver records SDK-summary lock wait and generator work separately
/// from the first Analyzer request.
class ResolverInitializationProfile {
  ResolverInitializationProfile({required this.enabled});

  final bool enabled;
  int packageConfigLoadUs = 0;
  int resolverConstructorUs = 0;
  int sdkSummaryUs = 0;
  int sdkSummaryLockWaitUs = 0;
  int sdkSummaryAfterLockUs = 0;
  int sdkSummaryReadUs = 0;
  int driverCreateUs = 0;
  int buildResolverCtorUs = 0;
  int resolverFirstGetUs = 0;
  int resolverPostSdkSummaryUs = 0;
  String? firstBuilder;
  String? firstInput;
  bool _emitted = false;

  void recordFirstGet(
    int elapsedUs, {
    required String builder,
    required String input,
  }) {
    resolverFirstGetUs = elapsedUs;
    resolverPostSdkSummaryUs = (elapsedUs - sdkSummaryUs).clamp(0, elapsedUs);
    firstBuilder = builder;
    firstInput = input;
  }

  void emit() {
    if (!enabled || _emitted) return;
    _emitted = true;
    stderr.writeln(
      'Dart resolver metrics: ${jsonEncode(<String, dynamic>{'builder': firstBuilder, 'input': firstInput, 'package_config_load_us': packageConfigLoadUs, 'resolver_constructor_us': resolverConstructorUs, 'resolver_sdk_summary_us': sdkSummaryUs, 'resolver_sdk_summary_lock_wait_us': sdkSummaryLockWaitUs, 'resolver_sdk_summary_after_lock_us': sdkSummaryAfterLockUs, 'resolver_sdk_summary_read_us': sdkSummaryReadUs, 'driver_create_us': driverCreateUs, 'build_resolver_ctor_us': buildResolverCtorUs, 'resolver_first_get_us': resolverFirstGetUs, 'resolver_post_sdk_summary_us': resolverPostSdkSummaryUs})}',
    );
  }
}
