# FVM dependency resolution changes

Only an accelerator path dev dependency was added. Original constraints and
builder configuration were preserved; no overrides. The original pub get
left the upstream lock byte-identical. The complete introduced/removed/version
change set follows (pub reports 27 changed dependencies, counting removals).

The lock SDK range changes from `>=3.6.0 <4.0.0` to `>=3.13.0 <4.0.0`,
because selected Analyzer 14.6.0/_fe_analyzer_shared 110.0.0 require Dart
^3.13.0. The root pubspec SDK constraint was not changed.

| Package | Original lock | With accelerator |
| --- | --- | --- |
| _fe_analyzer_shared | 80.0.0 | 110.0.0 |
| analyzer | 7.3.0 | 14.6.0 |
| archive | — | 4.5.2 |
| build | 2.4.2 | 4.0.11 |
| build_config | 1.1.2 | 1.3.3 |
| build_resolvers | 2.4.4 | — |
| build_runner | 2.4.15 | 2.16.2 |
| build_runner_accelerator | — | 0.14.1 |
| build_runner_core | 8.0.0 | — |
| build_version | 2.1.1 | 2.2.1 |
| built_value | 8.9.5 | 8.13.0 |
| cli_config | — | 0.2.0 |
| code_builder | 4.10.1 | — |
| coverage | 1.11.1 | 1.15.1 |
| cryptography | — | 2.9.0 |
| dart_mappable | 4.5.0 | 4.10.0 |
| dart_mappable_builder | 4.5.0 | 4.10.0 |
| dart_style | 3.0.1 | 3.1.14 |
| js | 0.6.7 | — |
| meta | 1.16.0 | 1.19.0 |
| pool | 1.5.1 | 1.5.3 |
| posix | — | 6.5.2 |
| source_gen | 2.0.0 | 4.3.1 |
| test | 1.25.15 | 1.33.0 |
| test_api | 0.7.4 | 0.7.15 |
| test_core | 0.6.8 | 0.6.21 |
| timing | 1.0.2 | — |
