import 'package:json_annotation/json_annotation.dart';

part 'model_303.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model303 {
  const Model303({required this.id, required this.value});

  final int id;
  final String value;

  factory Model303.fromJson(Map<String, dynamic> json) =>
      _$Model303FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model303ToJson(this);
}
