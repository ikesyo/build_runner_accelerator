import 'package:json_annotation/json_annotation.dart';

part 'model_348.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model348 {
  const Model348({required this.id, required this.value});

  final int id;
  final String value;

  factory Model348.fromJson(Map<String, dynamic> json) =>
      _$Model348FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model348ToJson(this);
}
