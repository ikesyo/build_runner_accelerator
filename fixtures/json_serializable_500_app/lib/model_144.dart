import 'package:json_annotation/json_annotation.dart';

part 'model_144.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model144 {
  const Model144({required this.id, required this.value});

  final int id;
  final String value;

  factory Model144.fromJson(Map<String, dynamic> json) =>
      _$Model144FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model144ToJson(this);
}
