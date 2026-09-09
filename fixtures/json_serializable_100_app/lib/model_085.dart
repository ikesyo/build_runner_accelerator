import 'package:json_annotation/json_annotation.dart';

part 'model_085.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model085 {
  const Model085({required this.id, required this.value});

  final int id;
  final String value;

  factory Model085.fromJson(Map<String, dynamic> json) =>
      _$Model085FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model085ToJson(this);
}
