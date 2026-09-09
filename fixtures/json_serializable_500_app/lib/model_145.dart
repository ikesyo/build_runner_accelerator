import 'package:json_annotation/json_annotation.dart';

part 'model_145.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model145 {
  const Model145({required this.id, required this.value});

  final int id;
  final String value;

  factory Model145.fromJson(Map<String, dynamic> json) =>
      _$Model145FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model145ToJson(this);
}
