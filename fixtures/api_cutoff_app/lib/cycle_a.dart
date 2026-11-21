import 'cycle_b.dart';

/// One side of an import cycle in the fixture API.
class CycleA {
  /// Names the other side.
  String partner() => CycleB().name();

  /// A value from this side.
  int valueA() => 1;
}
