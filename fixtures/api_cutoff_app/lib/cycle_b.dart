import 'cycle_a.dart';

/// The other side of an import cycle in the fixture API.
class CycleB {
  /// Names this side.
  String name() => 'cycle-b-v1';

  /// A value from the other side.
  int valueB() => CycleA().valueA();
}
