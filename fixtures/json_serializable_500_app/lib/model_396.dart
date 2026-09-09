import 'package:json_annotation/json_annotation.dart';

part 'model_396.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model396 {
  const Model396({required this.id, required this.value});

  final int id;
  final String value;

  factory Model396.fromJson(Map<String, dynamic> json) =>
      _$Model396FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model396ToJson(this);
}
