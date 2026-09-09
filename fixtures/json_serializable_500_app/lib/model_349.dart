import 'package:json_annotation/json_annotation.dart';

part 'model_349.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model349 {
  const Model349({required this.id, required this.value});

  final int id;
  final String value;

  factory Model349.fromJson(Map<String, dynamic> json) =>
      _$Model349FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model349ToJson(this);
}
