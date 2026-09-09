import 'package:json_annotation/json_annotation.dart';

part 'model_485.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model485 {
  const Model485({required this.id, required this.value});

  final int id;
  final String value;

  factory Model485.fromJson(Map<String, dynamic> json) =>
      _$Model485FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model485ToJson(this);
}
