import 'package:json_annotation/json_annotation.dart';

part 'model_470.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model470 {
  const Model470({required this.id, required this.value});

  final int id;
  final String value;

  factory Model470.fromJson(Map<String, dynamic> json) =>
      _$Model470FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model470ToJson(this);
}
