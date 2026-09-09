import 'package:json_annotation/json_annotation.dart';

part 'model_406.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model406 {
  const Model406({required this.id, required this.value});

  final int id;
  final String value;

  factory Model406.fromJson(Map<String, dynamic> json) =>
      _$Model406FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model406ToJson(this);
}
