import 'package:json_annotation/json_annotation.dart';

part 'model_155.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model155 {
  const Model155({required this.id, required this.value});

  final int id;
  final String value;

  factory Model155.fromJson(Map<String, dynamic> json) =>
      _$Model155FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model155ToJson(this);
}
