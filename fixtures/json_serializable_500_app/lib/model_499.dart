import 'package:json_annotation/json_annotation.dart';

part 'model_499.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model499 {
  const Model499({required this.id, required this.value});

  final int id;
  final String value;

  factory Model499.fromJson(Map<String, dynamic> json) =>
      _$Model499FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model499ToJson(this);
}
