import 'package:json_annotation/json_annotation.dart';

part 'model_359.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model359 {
  const Model359({required this.id, required this.value});

  final int id;
  final String value;

  factory Model359.fromJson(Map<String, dynamic> json) =>
      _$Model359FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model359ToJson(this);
}
