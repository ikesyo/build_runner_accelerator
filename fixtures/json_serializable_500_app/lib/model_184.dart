import 'package:json_annotation/json_annotation.dart';

part 'model_184.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model184 {
  const Model184({required this.id, required this.value});

  final int id;
  final String value;

  factory Model184.fromJson(Map<String, dynamic> json) =>
      _$Model184FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model184ToJson(this);
}
