import 'package:json_annotation/json_annotation.dart';

part 'model_364.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model364 {
  const Model364({required this.id, required this.value});

  final int id;
  final String value;

  factory Model364.fromJson(Map<String, dynamic> json) =>
      _$Model364FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model364ToJson(this);
}
