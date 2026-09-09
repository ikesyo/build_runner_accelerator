import 'package:json_annotation/json_annotation.dart';

part 'model_281.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model281 {
  const Model281({required this.id, required this.value});

  final int id;
  final String value;

  factory Model281.fromJson(Map<String, dynamic> json) =>
      _$Model281FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model281ToJson(this);
}
