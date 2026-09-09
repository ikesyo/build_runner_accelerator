import 'dart:convert';
import 'dart:io';

import 'package:build_runner/src/build/resolver/resolvers_impl.dart'
    show ResolversImpl;
import 'package:package_config/package_config.dart';

/// Creates the resolver used by the current build_runner execution layer.
///
/// `build_resolvers` was folded into build_runner in the current stable
/// release. Supplying the worker's package config keeps the resolver's
/// analyzer view aligned with the remote asset filesystem.
ResolversImpl createResolver(
  PackageConfig packageConfig,
  ResolverInitializationProfile profile,
) {
  final constructorTimer = profile.enabled ? (Stopwatch()..start()) : null;
  final resolver = ResolversImpl.custom(packageConfig: packageConfig);
  if (constructorTimer != null) {
    profile.resolverConstructorUs = constructorTimer.elapsedMicroseconds;
  }
  return resolver;
}

/// Stage timings for the lazy Analyzer resolver initialization path.
///
/// The current resolver owns SDK-summary generation internally. The legacy
/// worker exposed separate build_resolvers SDK-summary timings, so those
/// fields remain in the wire-level diagnostics as zero-valued compatibility
/// fields until build_runner exposes equivalent hooks.
class ResolverInitializationProfile {
  ResolverInitializationProfile({required this.enabled});

  final bool enabled;
  int packageConfigLoadUs = 0;
  int resolverConstructorUs = 0;
  int sdkSummaryUs = 0;
  int sdkSummaryLockWaitUs = 0;
  int sdkSummaryAfterLockUs = 0;
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
    resolverPostSdkSummaryUs = elapsedUs;
    firstBuilder = builder;
    firstInput = input;
  }

  void emit() {
    if (!enabled || _emitted) return;
    _emitted = true;
    stderr.writeln(
      'Dart resolver metrics: ${jsonEncode(<String, dynamic>{'builder': firstBuilder, 'input': firstInput, 'package_config_load_us': packageConfigLoadUs, 'resolver_constructor_us': resolverConstructorUs, 'resolver_sdk_summary_us': sdkSummaryUs, 'resolver_sdk_summary_lock_wait_us': sdkSummaryLockWaitUs, 'resolver_sdk_summary_after_lock_us': sdkSummaryAfterLockUs, 'resolver_first_get_us': resolverFirstGetUs, 'resolver_post_sdk_summary_us': resolverPostSdkSummaryUs})}',
    );
  }
}
