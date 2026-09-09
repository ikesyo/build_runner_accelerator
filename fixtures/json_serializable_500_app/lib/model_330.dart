import 'package:json_annotation/json_annotation.dart';

part 'model_330.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model330 {
  const Model330({required this.id, required this.value});

  final int id;
  final String value;

  factory Model330.fromJson(Map<String, dynamic> json) =>
      _$Model330FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model330ToJson(this);
}
