import 'package:json_annotation/json_annotation.dart';

part 'model_286.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model286 {
  const Model286({required this.id, required this.value});

  final int id;
  final String value;

  factory Model286.fromJson(Map<String, dynamic> json) =>
      _$Model286FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model286ToJson(this);
}
