import 'package:json_annotation/json_annotation.dart';

part 'model_276.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model276 {
  const Model276({required this.id, required this.value});

  final int id;
  final String value;

  factory Model276.fromJson(Map<String, dynamic> json) =>
      _$Model276FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model276ToJson(this);
}
