import 'package:json_annotation/json_annotation.dart';

part 'model_392.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model392 {
  const Model392({required this.id, required this.value});

  final int id;
  final String value;

  factory Model392.fromJson(Map<String, dynamic> json) =>
      _$Model392FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model392ToJson(this);
}
