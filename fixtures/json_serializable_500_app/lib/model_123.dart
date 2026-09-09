import 'package:json_annotation/json_annotation.dart';

part 'model_123.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model123 {
  const Model123({required this.id, required this.value});

  final int id;
  final String value;

  factory Model123.fromJson(Map<String, dynamic> json) =>
      _$Model123FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model123ToJson(this);
}
