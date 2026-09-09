import 'package:json_annotation/json_annotation.dart';

part 'model_355.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model355 {
  const Model355({required this.id, required this.value});

  final int id;
  final String value;

  factory Model355.fromJson(Map<String, dynamic> json) =>
      _$Model355FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model355ToJson(this);
}
