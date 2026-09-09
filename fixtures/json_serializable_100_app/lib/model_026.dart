import 'package:json_annotation/json_annotation.dart';

part 'model_026.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model026 {
  const Model026({required this.id, required this.value});

  final int id;
  final String value;

  factory Model026.fromJson(Map<String, dynamic> json) =>
      _$Model026FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model026ToJson(this);
}
