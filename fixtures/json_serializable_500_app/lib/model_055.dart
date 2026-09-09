import 'package:json_annotation/json_annotation.dart';

part 'model_055.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model055 {
  const Model055({required this.id, required this.value});

  final int id;
  final String value;

  factory Model055.fromJson(Map<String, dynamic> json) =>
      _$Model055FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model055ToJson(this);
}
