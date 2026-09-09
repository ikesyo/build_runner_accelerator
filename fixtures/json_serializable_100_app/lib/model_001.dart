import 'package:json_annotation/json_annotation.dart';

part 'model_001.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model001 {
  const Model001({required this.id, required this.value});

  final int id;
  final String value;

  factory Model001.fromJson(Map<String, dynamic> json) =>
      _$Model001FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model001ToJson(this);
}
