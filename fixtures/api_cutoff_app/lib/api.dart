import 'cycle_a.dart';

part 'api_part.dart';

/// A widget in the fixture API.
class Widget {
  /// Renders the widget.
  String render() => 'widget-v1';

  /// Extra rendering.
  String extra() => 'extra';
}

/// A gadget in the fixture API.
class Gadget {
  /// Computes a value.
  int compute() => 42;
}

/// Limits for the fixture API.
// A plain comment: not documentation, so it is outside the API
// fingerprint the cutoff compares.
class Limits {
  /// The maximum number of items.
  final int maxItems;

  /// The hard ceiling, set by a field initializer.
  final int ceiling = 100;

  /// Creates limits with a const constructor.
  const Limits({this.maxItems = 10});
}

/// The cycle entry point observed through the fixture API.
CycleA cycleEntry() => CycleA();
