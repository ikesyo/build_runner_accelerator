import 'package:json_annotation/json_annotation.dart';

part 'model_340.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model340 {
  const Model340({required this.id, required this.value});

  final int id;
  final String value;

  factory Model340.fromJson(Map<String, dynamic> json) =>
      _$Model340FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model340ToJson(this);
}
