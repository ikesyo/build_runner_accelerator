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
