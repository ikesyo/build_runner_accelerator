import 'package:json_annotation/json_annotation.dart';

part 'model_233.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model233 {
  const Model233({required this.id, required this.value});

  final int id;
  final String value;

  factory Model233.fromJson(Map<String, dynamic> json) =>
      _$Model233FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model233ToJson(this);
}
