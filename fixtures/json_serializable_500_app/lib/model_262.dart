import 'package:json_annotation/json_annotation.dart';

part 'model_262.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model262 {
  const Model262({required this.id, required this.value});

  final int id;
  final String value;

  factory Model262.fromJson(Map<String, dynamic> json) =>
      _$Model262FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model262ToJson(this);
}
